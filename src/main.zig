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
    data_dir: []const u8,
    source_path: ?[]const u8,
    ci_working_path: []const u8,

    pub const default: Options = .{
        .config_path = "./config.ini",
        .data_dir = "data/",
        .source_path = null,
        .ci_working_path = "working/",
    };
};

pub const Config = @import("Config.zig");

//pub var global_config = &Config.global;
pub var config_ini: Ini.Config(Config) = .{ .ini = .empty };

const Auth = @import("Auth.zig");

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;

    var options: Options = .default;
    var runmode: verse.Server.Options.RunMode = .{ .zwsgi = undefined };

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
            runmode = .{ .zwsgi = undefined };
        } else if (std.mem.eql(u8, arg, "http")) {
            runmode = .{ .http = undefined };
        } else if (std.mem.eql(u8, arg, "-c")) {
            if (args.next()) |passed_config_file| {
                options.config_path = passed_config_file;
            } else {
                std.debug.print("config file not provided", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "-d")) {
            if (args.next()) |data_dir| {
                options.data_dir = data_dir;
            } else {
                std.debug.print("data dir not provided", .{});
                std.process.exit(1);
            }
        } else {
            std.debug.print("unknown arg '{s}'", .{arg});
        }
    }

    // *SIGH*, I love zig master :/
    var threaded: std.Io.Threaded = .init(a, .{ .environ = init.minimal.environ });
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    var cfg_file: ?std.Io.File = null;
    if (findConfig(options.config_path)) |cfg| {
        std.debug.print("reading from '{s}'\n", .{cfg});
        cfg_file = try cwd.openFile(io, options.config_path, .{});
    }

    var cfg_data: []u8 = &.{};
    defer a.free(cfg_data);
    if (cfg_file) |*cf| {
        const len = try cf.length(io);
        cfg_data = try a.alloc(u8, len);
        var config_reader = cf.reader(io, cfg_data);
        config_ini = try Ini.Config(Config).init(&config_reader.interface, a);
        Config.global = try config_ini.resolve();
    }
    defer config_ini.raze(a);

    if (Config.global.owner) |owner| {
        if (owner.email) |email| {
            log.debug("{s}", .{email});
        }
    }

    try Database.init(.{ .backing = .{ .filesys = .{ .dir = options.data_dir } } }, io);
    defer Database.raze(io);

    const cache = Cache.init(a);
    defer cache.raze();

    const socket_file = if (Config.global.server.?.sock) |socket| socket else "./srctree.sock";
    log.debug("sock: {s}", .{socket_file});

    if (Config.global.server) |srv| {
        if (srv.remove_on_start) {
            Io.Dir.cwd().deleteFile(io, socket_file) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }

    var agent: Repo.Agent = .init(.{
        .enabled = Config.global.agent.?.enabled,
        .upstream = .{
            .push = Config.global.agent.?.upstream_push,
            .pull = Config.global.agent.?.upstream_pull,
        },
        .downstream = .{
            .push = Config.global.agent.?.downstream_push,
            .pull = Config.global.agent.?.downstream_pull,
        },
        .skips = Config.global.agent.?.skip_repos,
    }, io);
    try agent.startThread();
    defer agent.joinThread();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const auth_alloc = arena.allocator();
    var auth = Auth.init(auth_alloc, io);
    defer auth.raze();
    var mtls = Auth.init(auth_alloc, io);

    if (Config.global.repos) |repo_config| {
        if (repo_config.dir) |public_repo_dir|
            Repo.dirs.public = public_repo_dir;
        if (repo_config.private_dir) |private_repo_dir|
            Repo.dirs.private = private_repo_dir;
    }

    Srctree.endpoints.serve(a, .{
        .mode = switch (runmode) {
            .http => .{ .http = .localdevel },
            .zwsgi => .{ .zwsgi = .{ .file = socket_file, .chmod = 0o777, .stats = true } },
            else => unreachable,
        },
        .auth = &mtls.auth,
        .threads = 4,
        .stats = .{ .auth_mode = .sensitive },
    }) catch {
        if (@errorReturnTrace()) |trace|
            std.debug.dumpErrorReturnTrace(trace);
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

const Database = @import("database.zig");
const Repo = @import("Repo.zig");
const Types = @import("types.zig");

const Ini = @import("ini.zig");
const Cache = @import("cache.zig");

const Srctree = @import("srctree.zig");
