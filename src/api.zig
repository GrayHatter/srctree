const std = @import("std");
const routes = @import("routes.zig");
const ROUTE = routes.ROUTE;
const Context = @import("context.zig");

const endpoints = [_]routes.MatchRouter{};

pub fn router(ctx: *Context) routes.Error!routes.Callable {
    _ = ctx;
    return error.Unrouteable;
}
