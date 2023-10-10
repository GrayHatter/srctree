const std = @import("std");
const Allocator = std.mem.Allocator;
const Server = std.http.Server;
const Route = @import("route.zig");
const MAX_HEADER_SIZE = 1 <<| 13;

pub fn serve(a: Allocator, srv: *Server) !void {
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

            //const ep = Route.route(response.request.target);
            //ep(&response, body) catch |e| switch (e) {
            //    error.AndExit => break :connection,
            //    else => return e,
            //};
        }
    }
}
