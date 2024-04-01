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

const HOST = "127.0.0.1";
const PORT = 2000;
const FILE = "./srctree.sock";

test "main" {
    std.testing.refAllDecls(@This());
    _ = HTML.html(&[0]HTML.Element{});
    std.testing.refAllDecls(@import("git.zig"));
}

var print_mutex = Thread.Mutex{};

pub fn print(comptime format: []const u8, args: anytype) !void {
    print_mutex.lock();
    defer print_mutex.unlock();

    const out = std.io.getStdOut().writer();
    try out.print(format, args);
}

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
    , .{arg0}) catch std.process.exit(255);
    if (long) {}
    std.process.exit(0);
}

const RunMode = enum {
    unix,
    http,
    other,
    stop,
};

var runmode: RunMode = .unix;

const Options = struct {
    source_path: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 12 }){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    Template.init(a);
    defer Template.raze(a);

    var args = std.process.args();
    arg0 = args.next() orelse "tree";
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
            try print("unknown arg '{s}'", .{arg});
        }
    }

    var cwd = std.fs.cwd();
    var ini: Ini.Config = Ini.default(a) catch |e| switch (e) {
        error.FileNotFound => Ini.Config.empty(),
        else => return e,
    };

    defer ini.raze(a);

    if (ini.get("owner")) |ns| {
        if (ns.get("email")) |email| {
            if (false) std.log.info("{s}\n", .{email});
        }
    }

    try Database.init(.{});
    defer Database.raze();

    const thread = try Thread.spawn(.{}, Repos.updateThread, .{});
    defer thread.join();

    switch (runmode) {
        .unix => {
            if (cwd.access(FILE, .{})) {
                try cwd.deleteFile(FILE);
            } else |_| {}

            const uaddr = try std.net.Address.initUnix(FILE);
            var server = try uaddr.listen(.{});
            defer server.deinit();

            const path = try std.fs.cwd().realpathAlloc(a, FILE);
            defer a.free(path);
            const zpath = try a.dupeZ(u8, path);
            defer a.free(zpath);
            const mode = std.os.linux.chmod(zpath, 0o777);
            if (false) std.debug.print("mode {o}\n", .{mode});
            try print("Unix server listening\n", .{});

            zWSGI.serve(a, &server) catch {
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
                std.posix.exit(1);
            };
        },
        .http => {
            unreachable;
            // I don't have time to read through the whole update before I know
            // it's not gonna change again real soon... fucking zig...
            //var srv = Server.init(a, .{ .reuse_address = true });

            //const addr = std.net.Address.parseIp(HOST, PORT) catch unreachable;
            //try srv.listen(addr);
            //try print("HTTP Server listening\n", .{});

            //HTTP.serve(a, &srv) catch {
            //    if (@errorReturnTrace()) |trace| {
            //        std.debug.dumpStackTrace(trace.*);
            //    }
            //    std.os.exit(1);
            //};
        },
        else => {},
    }
}

test "simple test" {
    //const a = std.testing.allocator;

    try std.testing.expect(true);
}
