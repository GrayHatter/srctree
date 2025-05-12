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

pub const SrcConfig = struct {
    owner: ?struct {
        email: ?[]const u8,
        tz: ?[]const u8,
    },
    agent: ?struct {
        enabled: bool = false,
        push_upstream: bool = false,
    },
    server: ?struct {
        sock: ?[]const u8,
        remove_on_start: bool = false,
    },
};

// No, I don't like this
pub var root_ini: ?Ini.Config(SrcConfig) = null;
pub var global_config: SrcConfig = undefined;

const Auth = struct {
    alloc: Allocator,

    pub fn init(a: Allocator) Auth {
        return .{
            .alloc = a,
        };
    }

    pub fn raze(_: Auth) void {}

    pub fn provider(self: *Auth) verse.auth.Provider {
        return .{
            .ctx = self,
            .vtable = .{
                .authenticate = null,
                .valid = null,
                .create_session = null,
                .get_cookie = null,
                .lookup_user = lookupUser,
            },
        };
    }

    pub fn lookupUser(ptr: *anyopaque, user_id: []const u8) !verse.auth.User {
        const auth: *Auth = @ptrCast(@alignCast(ptr));
        const user = Types.User.findMTLSFingerprint(auth.alloc, user_id) catch |err| {
            std.debug.print("mtls lookup error {}\n", .{err});
            return error.UnknownUser;
        };
        return .{
            .username = user.username,
        };
    }
};

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

    var config = Ini.Config(SrcConfig).fromFile(a, cfg_file.?) catch |e| switch (e) {
        //error.FileNotFound => Ini.Config.empty(),
        else => return e,
    };
    defer config.raze();
    root_ini = config;

    const src_conf = try config.config();
    global_config = src_conf;

    if (config.get("owner")) |ns| {
        if (ns.get("email")) |email| {
            log.debug("{s}", .{email});
        }
    }

    try Database.init(.{});
    defer Database.raze();

    const cache = try Cache.init(a);
    defer cache.raze();

    var agent_config: Repos.AgentConfig = .{
        .g_config = &src_conf,
    };

    if (src_conf.server) |srv| {
        if (srv.remove_on_start) {
            cwd.deleteFile("./srctree.sock") catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }

    if (src_conf.agent.?.enabled) {
        const thread = try Thread.spawn(.{}, Repos.updateThread, .{&agent_config});
        defer thread.join();
    }

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const auth_alloc = arena.allocator();
    var auth = Auth.init(auth_alloc);
    defer auth.raze();
    var mtls = verse.auth.MTLS{
        .base = auth.provider(),
    };

    if (src_conf.server) |srvcfg| {
        if (srvcfg.sock) |sock| {
            std.debug.print("sock: {s}\n", .{sock});
        }
    }

    var endpoints = Srctree.endpoints.init(a);
    endpoints.serve(.{
        .mode = .{ .zwsgi = .{ .file = "./srctree.sock", .chmod = 0o777 } },
        .auth = mtls.provider(),
        .threads = 4,
    }) catch {
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        std.posix.exit(1);
    };
    agent_config.running = false;
}
