const std = @import("std");

const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Server = std.http.Server;

const Database = @import("database.zig");
const HTML = @import("html.zig");
const Template = @import("template.zig");
const Route = @import("routes.zig");
const Endpoint = @import("endpoint.zig");
const Repos = @import("repos.zig");
const EndpointErr = Endpoint.Error;
const HTTP = @import("http.zig");
const zWSGI = @import("zwsgi.zig");
const Ini = @import("ini.zig");
const Cache = @import("cache.zig");

const Srctree = @import("srctree.zig");

test "main" {
    std.testing.refAllDecls(@This());
    _ = HTML.html(&[0]HTML.Element{});
    std.testing.refAllDecls(@import("git.zig"));
}

// TODO make thread safe
const print = std.debug.print;

var arg0: []const u8 = undefined;

fn usage(long: bool) noreturn {
    print(
        \\{s} [type]
        \\
        \\ help, usage -h, --help : this message
        \\
        \\ unix : unix socket [default]
        \\ http : http server
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

// TODO delete me
var runmode: zWSGI.RunMode = .unix;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 12 }){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    Template.init(a);
    defer Template.raze(a);

    var args = std.process.args();
    arg0 = args.next() orelse "srctree";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--help") or
            std.mem.eql(u8, arg, "help") or
            std.mem.eql(u8, arg, "usage"))
        {
            usage(!std.mem.eql(u8, arg, "-h"));
        } else if (std.mem.eql(u8, arg, "unix")) {
            runmode = .unix;
        } else if (std.mem.eql(u8, arg, "http")) {
            runmode = .http;
        } else {
            print("unknown arg '{s}'", .{arg});
        }
    }

    var cwd = std.fs.cwd();
    var cfg_file: ?std.fs.File = null;
    if (findConfig("./config.ini")) |cfg| {
        std.debug.print("config not implemented\n", .{});
        std.debug.print("should read '{s}'\n", .{cfg});
        cfg_file = try cwd.openFile("./config.ini", .{});
    }

    var config: Ini.Config = Ini.fromFile(a, cfg_file.?) catch |e| switch (e) {
        //error.FileNotFound => Ini.Config.empty(),
        else => return e,
    };

    defer config.raze();

    if (config.get("owner")) |ns| {
        if (ns.get("email")) |email| {
            if (false) std.log.info("{s}\n", .{email});
        }
    }

    try Database.init(.{});
    defer Database.raze();

    _ = try Cache.init(a);
    defer Cache.raze();

    var agent_config: Repos.AgentConfig = .{
        .g_config = &config,
    };

    const thread = try Thread.spawn(.{}, Repos.updateThread, .{&agent_config});
    defer thread.join();

    var zwsgi: zWSGI = .{
        .alloc = a,
        .config = config,
        .routefn = Srctree.router,
        .buildfn = Srctree.build,
    };

    zwsgi.serve() catch {
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        std.posix.exit(1);
    };
}

test "simple test" {
    //const a = std.testing.allocator;

    try std.testing.expect(true);
}
