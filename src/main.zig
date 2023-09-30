const std = @import("std");
const Server = std.http.Server;

const MAX_HEADER_SIZE = 1 << 14;
const HOST = "127.0.0.1";
const PORT = 2000;

fn route() void {}

fn respond(r: *Server.Response) !void {
    const a = r.allocator;
    std.log.info("{s} {s} {s}", .{
        @tagName(r.request.method),
        @tagName(r.request.version),
        r.request.target,
    });

    const andexit = std.mem.eql(u8, r.request.target, "/bye");

    const body = try r.reader().readAllAlloc(a, 8192);
    defer a.free(body);

    if (r.request.headers.contains("connection")) {
        try r.headers.append("connection", "keep-alive");
    }
    const MSG = if (andexit) "bye!\n" else "Hi, mom!\n";
    r.transfer_encoding = .{ .content_length = MSG.len };

    try r.headers.append("content-type", "text/plain");
    try r.do();
    try r.writeAll(MSG);
    try r.finish();

    if (andexit) return error.AndExit;
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

            respond(&response) catch |e| switch (e) {
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
