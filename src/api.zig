const std = @import("std");
const Allocator = std.mem.Allocator;
const routes = @import("routes.zig");
const ROUTE = routes.ROUTE;
const Context = @import("context.zig");

const endpoints = [_]routes.MatchRouter{};

const APIRouteData = struct {
    alloc: Allocator,
    version: usize = 0,

    pub fn init(a: Allocator) !*APIRouteData {
        const rd = try a.create(APIRouteData);
        rd.* = .{
            .alloc = a,
        };
        return rd;
    }
};

pub fn router(ctx: *Context) routes.Error!routes.Callable {
    const rd = try APIRouteData.init(ctx.alloc);
    ctx.route_ctx = rd;

    return heartbeat;
}

const HeartBeat = struct {
    nice: usize = 0,
};

fn heartbeat(ctx: *Context) routes.Error!void {
    return try ctx.sendJSON(HeartBeat{ .nice = 69 });
}
