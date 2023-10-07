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

fn uwsgiHeader(a: std.mem.Allocator, acpt: std.net.StreamServer.Connection) ![][]u8 {
    var list = std.ArrayList([]u8).init(a);

    // TODO packed
    const uHEADER = extern struct {
        mod1: u8 = 0,
        size: u16 = 0,
        mod2: u8 = 0,
    };

    var uwsgi_header: *uHEADER = undefined;
    var h_buf: [4]u8 align(@alignOf(uHEADER)) = .{ 0, 0, 0, 0 };
    _ = try acpt.stream.read(&h_buf);
    uwsgi_header = @as(*uHEADER, @ptrCast(&h_buf));
    std.log.info("header {}", .{uwsgi_header});
    var rsize = [1]u8{0};
    var rcount: usize = 0;

    var b: [8192]u8 = undefined;
    header: while (true) {
        rcount = 0;
        while (try acpt.stream.read(&rsize) != 0) {
            if (rsize[0] == 0) {
                if (rcount == 0) {
                    std.log.info("data [empty]", .{});
                    continue :header;
                }
                break;
            }
            rcount += rsize[0];
        }
        std.debug.assert(rcount > 0);
        var buf = b[0..rcount];
        var in = try acpt.stream.read(buf);
        std.debug.assert(in == rcount);
        std.log.info("data {any}", .{buf});
        std.log.info("data {s}", .{buf});
        if (in == 0 and rcount == 0) break;
    }

    return list.toOwnedSlice();
}

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
    var acpt = try usock.accept();

    _ = try uwsgiHeader(a, acpt);

    acpt.stream.close();
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
