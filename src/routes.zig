const std = @import("std");

const Allocator = std.mem.Allocator;

const Template = @import("template.zig");
const Context = @import("context.zig");
const Response = @import("response.zig");
const Request = @import("request.zig");
const endpoint = @import("endpoint.zig");
const HTML = @import("html.zig");

const Error = endpoint.Error;
pub const UriIter = std.mem.SplitIterator(u8, .sequence);

const div = HTML.div;
const span = HTML.span;

pub const Router = *const fn (*Context) Error!Endpoint;
pub const Endpoint = *const fn (*Context) Error!void;

pub const Methods = struct {
    pub const GET = 1;
    pub const HEAD = 2;
    pub const POST = 4;
    pub const PUT = 8;
    pub const DELETE = 16;
    pub const CONNECT = 32;
    pub const OPTIONS = 64;
    pub const TRACE = 128;
};

pub const MatchRouter = struct {
    name: []const u8,
    match: union(enum) {
        call: Endpoint,
        route: Router,
        simple: []const MatchRouter,
    },
    methods: u8 = Methods.GET,
};

const root = [_]MatchRouter{
    .{ .name = "admin", .match = .{ .simple = endpoint.admin } },
    .{ .name = "network", .match = .{ .simple = endpoint.network } },
    .{ .name = "repo", .match = .{ .route = endpoint.repo } },
    .{ .name = "repos", .match = .{ .route = endpoint.repo } },
    .{ .name = "todo", .match = .{ .simple = endpoint.todo } },
    .{ .name = "user", .match = .{ .call = endpoint.commitFlex } },
};

fn notfound(ctx: *Context) Error!void {
    ctx.response.status = .not_found;
    var tmpl = Template.find("4XX.html");
    tmpl.init(ctx.alloc);
    ctx.sendTemplate(&tmpl) catch unreachable;
}

fn default(ctx: *Context) Error!void {
    var tmpl = Template.find("index.html");
    tmpl.init(ctx.alloc);
    ctx.sendTemplate(&tmpl) catch unreachable;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn router(ctx: *Context, comptime routes: []const MatchRouter) Endpoint {
    const search = ctx.uri.peek() orelse return notfound;
    inline for (routes) |ep| {
        if (eql(search, ep.name)) {
            switch (ep.match) {
                .call => |call| {
                    if (@intFromEnum(ctx.request.method) & ep.methods > 0)
                        return call;
                },
                .route => |route| {
                    return route(ctx) catch |err| switch (err) {
                        error.Unrouteable => return notfound,
                        else => unreachable,
                    };
                },
                .simple => |simple| {
                    _ = ctx.uri.next();
                    if (ctx.uri.peek() == null and
                        std.mem.eql(u8, simple[0].name, "") and
                        simple[0].match == .call)
                        return simple[0].match.call;
                    return router(ctx, simple);
                },
            }
        }
    }
    return notfound;
}

pub fn baseRouter(ctx: *Context) Error!void {
    //std.debug.print("baserouter {s}\n", .{ctx.uri.peek().?});
    if (ctx.uri.peek()) |first| {
        if (first.len > 0) {
            const route: Endpoint = router(ctx, &root);
            return route(ctx);
        }
    }
    return default(ctx);
}
