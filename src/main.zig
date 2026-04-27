test "main" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("git.zig"));
    _ = &Auth;
}

pub const std_options: std.Options = .{
    .log_level = .info,
};

var arg0: []const u8 = undefined;
fn usage(long: bool) noreturn {
    std.debug.print(
        \\{s} [type]
        \\
        \\ help, usage -h, --help : this message
        \\
        \\ zwsgi : unix socket [default]
        \\ http  : http server
        \\
        \\ -s [directory] : directory to look for repos
        \\      (not yet implemented)
        \\
        \\ -c [config.file] : use this config file instead of trying to guess.
        \\
    , .{arg0});
    if (long) {}
    std.process.exit(0);
}

fn findConfig(target: []const u8) ?[]const u8 {
    if (target.len > 0) return target;

    if (std.os.linux.getuid() < 1000) {
        // TODO and uid shell not in /etc/shells
        // search in /etc/srctree/
    } else {
        // search in cwd, then home dir
    }

    return null;
}

const Options = struct {
    config_path: []const u8,
    source_path: []const u8,
};

pub const SrcConfig = struct {
    server: ?SrcConfig.Server,
    owner: ?Owner,
    repos: ?SrcConfig.Repos,
    agent: ?Agent,
    notifications: ?Notifications,

    pub const Server = struct {
        sock: ?[]const u8,
        remove_on_start: bool = false,
    };

    pub const Owner = struct {
        email: ?[]const u8,
        tz: ?[]const u8,
    };

    pub const Repos = struct {
        /// Directory of public repos
        dir: ?[]const u8,
        /// Directory of private repos
        private_dir: ?[]const u8,
        /// List of repos that should be hidden
        private_repos: ?[]const u8,
        unlisted_repos: ?[]const u8,
    };

    pub const Agent = struct {
        enabled: bool = false,
        skip_repos: ?[]const u8 = null,
        upstream_push: bool = false,
        upstream_pull: bool = false,
        downstream_push: bool = false,
        downstream_pull: bool = false,
    };

    pub const Notifications = struct {
        enabled: bool = false,
        sender: ?[]const u8 = null,
        receiver: ?[]const u8 = null,
    };

    pub const empty: SrcConfig = .{
        .server = null,
        .owner = null,
        .repos = null,
        .agent = null,
        .notifications = null,
    };
};

pub var global_config: SrcConfig = .empty;
pub var config_ini: Ini.Config(SrcConfig) = .{ .ini = .empty };

const Auth = @import("Auth.zig");

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;

    var runmode: verse.Server.RunModes = .zwsgi;

    var args = init.minimal.args.iterate();
    arg0 = args.next() orelse "srctree";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--help") or
            std.mem.eql(u8, arg, "help") or
            std.mem.eql(u8, arg, "usage"))
        {
            usage(!std.mem.eql(u8, arg, "-h"));
        } else if (std.mem.eql(u8, arg, "zwsgi")) {
            runmode = .zwsgi;
        } else if (std.mem.eql(u8, arg, "http")) {
            runmode = .http;
        } else {
            std.debug.print("unknown arg '{s}'", .{arg});
        }
    }

    // *SIGH*, I love zig master :/
    var threaded: std.Io.Threaded = .init(a, .{ .environ = init.minimal.environ });
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    var cfg_file: ?std.Io.File = null;
    if (findConfig("./config.ini")) |cfg| {
        std.debug.print("reading from '{s}'\n", .{cfg});
        cfg_file = try cwd.openFile(io, "./config.ini", .{});
    }

    var cfg_data: []u8 = &.{};
    defer a.free(cfg_data);
    if (cfg_file) |*cf| {
        const len = try cf.length(io);
        cfg_data = try a.alloc(u8, len);
        var config_reader = cf.reader(io, cfg_data);
        config_ini = try Ini.Config(SrcConfig).init(&config_reader.interface, a);
        global_config = try config_ini.resolve();
    }
    defer config_ini.raze(a);

    if (global_config.owner) |owner| {
        if (owner.email) |email| {
            log.debug("{s}", .{email});
        }
    }

    try Database.init(.{}, io);
    defer Database.raze(io);

    const cache = Cache.init(a);
    defer cache.raze();

    if (global_config.server) |srv| {
        if (srv.remove_on_start) {
            Io.Dir.cwd().deleteFile(io, "./srctree.sock") catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }

    var agent: Repos.Agent = .init(.{
        .enabled = global_config.agent.?.enabled,
        .upstream = .{
            .push = global_config.agent.?.upstream_push,
            .pull = global_config.agent.?.upstream_pull,
        },
        .downstream = .{
            .push = global_config.agent.?.downstream_push,
            .pull = global_config.agent.?.downstream_pull,
        },
        .skips = global_config.agent.?.skip_repos,
    }, io);
    try agent.startThread();
    defer agent.joinThread();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const auth_alloc = arena.allocator();
    var auth = Auth.init(auth_alloc, io);
    defer auth.raze();
    var mtls = verse.auth.MTLS{
        .base = auth.provider(),
    };

    if (global_config.server) |srvcfg| {
        if (srvcfg.sock) |sock| {
            std.debug.print("sock: {s}\n", .{sock});
        }
    }

    Srctree.endpoints.serve(a, .{
        .mode = if (runmode == .http)
            .{ .http = .public }
        else
            .{ .zwsgi = .{ .file = "./srctree.sock", .chmod = 0o777, .stats = true } },
        .auth = mtls.provider(),
        .threads = 4,
        .stats = .{ .auth_mode = .sensitive },
    }) catch {
        // TODO FIXME
        //if (@errorReturnTrace()) |trace| {
        //    std.debug.dumpStackTrace(trace);
        //}
        std.process.exit(1);
    };
    agent.enabled = false;
}

const std = @import("std");
const builtin = @import("builtin");
const verse = @import("verse");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Io = std.Io;
const Server = verse.Server;
const log = std.log;
pub const Abx = verse.abx;

const Database = @import("database.zig");
const Repos = @import("repos.zig");
const Types = @import("types.zig");

const Ini = @import("ini.zig");
const Cache = @import("cache.zig");

const Srctree = @import("srctree.zig");
