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
    if (eql(uri, "/bye")) return bye;
    if (eql(uri, "/tree")) return respond;
    if (eql(uri, "/commits")) return respond;
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

fn serve(srv: *Server, a: std.mem.Allocator) !void {
    outer: while (true) {
        var response = try srv.accept(.{
            .allocator = a,
            .header_strategy = .{ .dynamic = MAX_HEADER_SIZE },
        });
        defer response.deinit();
        //const request = response.request;

        while (response.reset() != .closing) {
            response.wait() catch |err| switch (err) {
                error.HttpHeadersInvalid => continue :outer,
                error.EndOfStream => continue,
                else => return err,
            };

            const ep = route(response.request.target);

            std.log.info("{s} {s} {s}", .{
                @tagName(response.request.method),
                @tagName(response.request.version),
                response.request.target,
            });

            const body = try response.reader().readAllAlloc(a, 8192);
            defer a.free(body);

            if (response.request.headers.contains("connection")) {
                try response.headers.append("connection", "keep-alive");
            }

            ep(&response, body) catch |e| switch (e) {
                error.AndExit => break :outer,
                else => return e,
            };
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 12 }){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var srv = Server.init(a, .{ .reuse_address = true });

    const addr = std.net.Address.parseIp(HOST, PORT) catch unreachable;
    try srv.listen(addr);
    std.log.info("Server listening\n", .{});

    serve(&srv, a) catch {
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
