const std = @import("std");
const Server = std.http.Server;

const MAX_HEADER_SIZE = 1 << 14;
const HOST = "127.0.0.1";
const PORT = 2000;

const EndpointErr = error{
    Unknown,
    AndExit,
    OutOfMemory,
};

pub const Endpoint = *const fn (*Server.Response, []const u8) EndpointErr!void;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn route(uri: []const u8) Endpoint {
    if (eql(uri, "/")) return respond;
    if (eql(uri, "/bye")) return bye;
    if (eql(uri, "/commits")) return respond;
    if (eql(uri, "/tree")) return respond;
    return notfound;
}

fn sendMsg(r: *Server.Response, msg: []const u8) !void {
    r.transfer_encoding = .{ .content_length = msg.len };

    try r.do();
    try r.writeAll(msg);
    try r.finish();
}

fn bye(r: *Server.Response, _: []const u8) EndpointErr!void {
    const MSG = "bye!\n";
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
    };
    return EndpointErr.AndExit;
}

fn notfound(r: *Server.Response, _: []const u8) EndpointErr!void {
    r.status = .not_found;
    r.do() catch unreachable;
}

fn respond(r: *Server.Response, _: []const u8) EndpointErr!void {
    if (r.request.headers.contains("connection")) {
        try r.headers.append("connection", "keep-alive");
    }
    try r.headers.append("content-type", "text/plain");
    const MSG = "Hi, mom!\n";
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
        return EndpointErr.AndExit;
    };
}

fn serveHttp(srv: *Server, a: std.mem.Allocator) !void {
    connection: while (true) {
        var response = try srv.accept(.{
            .allocator = a,
            .header_strategy = .{ .dynamic = MAX_HEADER_SIZE },
        });
        defer response.deinit();
        //const request = response.request;

        while (response.reset() != .closing) {
            response.wait() catch |err| switch (err) {
                error.HttpHeadersInvalid => continue :connection,
                error.EndOfStream => continue,
                else => return err,
            };
            std.log.info("{s} {s} {s}", .{
                @tagName(response.request.method),
                @tagName(response.request.version),
                response.request.target,
            });
            const body = try response.reader().readAllAlloc(a, 8192);
            defer a.free(body);

            try response.headers.append("Server", "Source Tree WebServer");

            if (response.request.headers.contains("connection")) {
                try response.headers.append("connection", "keep-alive");
            }

            const ep = route(response.request.target);
            ep(&response, body) catch |e| switch (e) {
                error.AndExit => break :connection,
                else => return e,
            };
        }
    }
}

test "uwsgi proto" {
    const a = uProtoHeader{
        .mod1 = 0,
        .size = 180,
        .mod2 = 0,
    };

    const z = @as([*]const u8, @ptrCast(&a));
    std.debug.print("{any} \n", .{@as([]const u8, z[0..4])});
}

// TODO packed
const uProtoHeader = packed struct {
    mod1: u8 = 0,
    size: u16 = 0,
    mod2: u8 = 0,
};

const uWSGIVar = struct {
    key: []const u8,
    val: []const u8,

    pub fn read(_: []u8) uWSGIVar {
        return uWSGIVar{ .key = "", .val = "" };
    }
};

fn uwsgiHeader(a: std.mem.Allocator, acpt: std.net.StreamServer.Connection) ![][]u8 {
    var list = std.ArrayList([]u8).init(a);

    var uwsgi_header = uProtoHeader{};
    var ptr: [*]u8 = @ptrCast(&uwsgi_header);
    _ = try acpt.stream.read(@alignCast(ptr[0..4]));

    std.log.info("header {any}", .{@as([]const u8, ptr[0..4])});
    std.log.info("header {}", .{uwsgi_header});

    var buf: []u8 = try a.alloc(u8, uwsgi_header.size);
    const read = try acpt.stream.read(buf);
    if (read != uwsgi_header.size) {
        std.log.err("unexpected read size {} {}", .{ read, uwsgi_header.size });
    }

    while (buf.len > 0) {
        var size = @as(u16, @bitCast(buf[0..2].*));
        buf = buf[2..];
        const key = buf[0..size];
        std.log.info("VAR {s} ({})[{any}] ", .{ key, size, key });
        buf = buf[size..];
        size = @as(u16, @bitCast(buf[0..2].*));
        buf = buf[2..];
        if (size > 0) {
            const val = buf[0..size];
            std.log.info("VAR {s} ({})[{any}] ", .{ val, size, val });
            buf = buf[size..];
        } else {
            std.log.info("VAR [empty value] ", .{});
        }
    }

    return list.toOwnedSlice();
}

const BLOB =
    \\HTTP/1.1 200 Found
    \\Server: zwsgi/0.0.0
    \\Content-Type: text/html
    \\Content-Length: 567
    \\
    \\<!DOCTYPE html>
    \\<html>
    \\<head>
    \\<title>zWSGI</title>
    \\<style>
    \\html { color-scheme: light dark; }
    \\body { width: 35em; margin: 0 auto;
    \\font-family: Tahoma, Verdana, Arial, sans-serif; }
    \\</style>
    \\</head>
    \\<body>
    \\<h1>Task Failed Successfully!</h1>
    \\<p>The git repo you're looing for is in another castle :(<br/>
    \\Please try again repeatedly... surely it'll work this time!</p>
    \\<p>If you are the system administrator you should already know why <br/>
    \\it's broken what are you still reading this for?!</p>
    \\<p><em>Faithfully yours, Geoff from Accounting.</em></p>
    \\</body>
    \\</html>
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 12 }){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var usock = std.net.StreamServer.init(.{});
    const FILE = "./srctree.sock";

    var cwd = std.fs.cwd();
    if (cwd.access(FILE, .{})) {
        try cwd.deleteFile(FILE);
    } else |_| {}

    const uaddr = try std.net.Address.initUnix(FILE);
    try usock.listen(uaddr);
    std.log.info("Unix server listening\n", .{});

    var path = try std.fs.cwd().realpathAlloc(a, FILE);
    var zpath = try a.dupeZ(u8, path);
    a.free(path);
    var mode = std.os.linux.chmod(zpath, 0o777);
    if (false) std.debug.print("mode {o}\n", .{mode});
    defer a.free(zpath);

    while (true) {
        var acpt = try usock.accept();
        _ = try uwsgiHeader(a, acpt);
        _ = try acpt.stream.write(BLOB);
        acpt.stream.close();
    }
    usock.close();

    var srv = Server.init(a, .{ .reuse_address = true });

    const addr = std.net.Address.parseIp(HOST, PORT) catch unreachable;
    try srv.listen(addr);
    std.log.info("Server listening\n", .{});

    serveHttp(&srv, a) catch {
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        std.os.exit(1);
    };
}

test "simple test" {
    //const a = std.testing.allocator;

    try std.testing.expect(true);
}
