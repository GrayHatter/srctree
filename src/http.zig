const std = @import("std");

const Allocator = std.mem.Allocator;
const Server = std.http.Server;

const Context = @import("context.zig");
const Request = @import("request.zig");
const Response = @import("response.zig");
const Router = @import("routes.zig");
const HttpPost = @import("http-post.zig");

const MAX_HEADER_SIZE = 1 <<| 13;

pub fn serve(a: Allocator, srv: *Server) !void {
    connection: while (true) {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var alloc = arena.allocator();

        var http_resp = try srv.accept(.{
            .allocator = alloc,
            .header_strategy = .{ .dynamic = MAX_HEADER_SIZE },
        });
        defer http_resp.deinit();
        //const request = response.request;

        while (http_resp.reset() != .closing) {
            http_resp.wait() catch |err| switch (err) {
                error.HttpHeadersInvalid => continue :connection,
                error.EndOfStream => continue,
                else => return err,
            };
            std.log.info("{s} {s} {s}", .{
                @tagName(http_resp.request.method),
                @tagName(http_resp.request.version),
                http_resp.request.target,
            });
            const body = try http_resp.reader().readAllAlloc(alloc, 8192);
            defer a.free(body);

            try http_resp.headers.append("Server", "Source Tree WebServer");

            if (http_resp.request.headers.contains("connection")) {
                try http_resp.headers.append("connection", "keep-alive");
            }

            var request = try Request.init(alloc, http_resp);
            var response = Response.init(alloc, &request);

            var post_data: HttpPost.PostData = undefined;

            var ctx = try Context.init(
                alloc,
                request,
                response,
                post_data,
            );
            Router.baseRouter(&ctx) catch |e| switch (e) {
                error.AndExit => break :connection,
                else => return e,
            };
        }
    }
}
