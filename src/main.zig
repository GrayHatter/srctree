const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const verse = @import("verse");
const print = std.debug.print;
const Server = verse.Server;
const log = std.log;

const Database = @import("database.zig");
const Repos = @import("repos.zig");
const Types = @import("types.zig");

const Ini = @import("ini.zig");
const Cache = @import("cache.zig");

const Srctree = @import("srctree.zig");

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
    print(
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

pub const SrcConfig = Ini.Config(struct {
    owner: ?struct {
        email: ?[]const u8,
        tz: ?[]const u8,
    },
    agent: ?Agent,
    server: ?struct {
        sock: ?[]const u8,
        remove_on_start: bool = false,
    },
    repos: ?struct {
        /// Directory of public repos
        repos: ?[]const u8,
        /// Directory of private repos
        private_repos: ?[]const u8,
        /// List of repos that should be hidden
        @"hidden-repos": ?[]const u8,
    },

    pub const Agent = struct {
        enabled: bool = false,
        upstream_push: bool = false,
        upstream_pull: bool = false,
        downstream_push: bool = false,
        downstream_pull: bool = false,
    };

    pub const empty: SrcConfig.Base = .{
        .owner = null,
        .agent = null,
        .server = null,
        .repos = null,
    };
});

pub var global_config: SrcConfig = .{ .config = .empty, .ctx = .empty };

const Auth = @import("Auth.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 12 }){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var runmode: verse.Server.RunModes = .zwsgi;

    var args = std.process.args();
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
            print("unknown arg '{s}'", .{arg});
        }
    }

    var cwd = std.fs.cwd();
    var cfg_file: ?std.fs.File = null;
    if (findConfig("./config.ini")) |cfg| {
        std.debug.print("reading from '{s}'\n", .{cfg});
        cfg_file = try cwd.openFile("./config.ini", .{});
    }

    global_config = SrcConfig.fromFile(a, cfg_file.?) catch |e| switch (e) {
        //error.FileNotFound => Ini.Config.empty(),
        else => return e,
    };
    defer global_config.raze(a);

    if (global_config.ctx.get("owner")) |ns| {
        if (ns.get("email")) |email| {
            log.debug("{s}", .{email});
        }
    }

    try Database.init(.{});
    defer Database.raze();

    const cache = Cache.init(a);
    defer cache.raze();

    if (global_config.config.server) |srv| {
        if (srv.remove_on_start) {
            cwd.deleteFile("./srctree.sock") catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }

    var agent: Repos.Agent = .init(.{
        .enabled = global_config.config.agent.?.enabled,
        .upstream = .{
            .push = global_config.config.agent.?.upstream_push,
            .pull = global_config.config.agent.?.upstream_pull,
        },
        .downstream = .{
            .push = global_config.config.agent.?.downstream_push,
            .pull = global_config.config.agent.?.downstream_pull,
        },
    });
    try agent.startThread();
    defer agent.joinThread();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const auth_alloc = arena.allocator();
    var auth = Auth.init(auth_alloc);
    defer auth.raze();
    var mtls = verse.auth.MTLS{
        .base = auth.provider(),
    };

    if (global_config.config.server) |srvcfg| {
        if (srvcfg.sock) |sock| {
            std.debug.print("sock: {s}\n", .{sock});
        }
    }

    var mode: verse.Server.RunMode = .{ .zwsgi = .{ .file = "./srctree.sock", .chmod = 0o777 } };
    if (runmode == .http) {
        mode = .{ .http = .{} };
    }

    Srctree.endpoints.serve(a, .{
        .mode = mode,
        .auth = mtls.provider(),
        .threads = 4,
        .stats = .{ .auth_mode = .sensitive },
    }) catch {
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        std.posix.exit(1);
    };
}
