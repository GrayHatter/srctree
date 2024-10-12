const std = @import("std");

const Allocator = std.mem.Allocator;

const api = @import("api.zig");
const Template = @import("template.zig");
const Context = @import("context.zig");
const Response = @import("response.zig");
const Request = @import("request.zig");
const HTML = @import("html.zig");
const StaticFile = @import("static-file.zig");

pub const Errors = @import("errors.zig");
pub const Error = Errors.ServerError || Errors.ClientError || Errors.NetworkError;

pub const UriIter = std.mem.SplitIterator(u8, .sequence);

const div = HTML.div;
const span = HTML.span;

pub const Router = *const fn (*Context) Error!Callable;
pub const Callable = *const fn (*Context) Error!void;

/// Methods is a struct so bitwise or will work as expected
pub const Methods = packed struct {
    GET: bool = false,
    HEAD: bool = false,
    POST: bool = false,
    PUT: bool = false,
    DELETE: bool = false,
    CONNECT: bool = false,
    OPTIONS: bool = false,
    TRACE: bool = false,

    pub fn matchMethod(self: Methods, req: Request.Methods) bool {
        return switch (req) {
            .GET => self.GET,
            .HEAD => self.HEAD,
            .POST => self.POST,
            .PUT => self.PUT,
            .DELETE => self.DELETE,
            .CONNECT => self.CONNECT,
            .OPTIONS => self.OPTIONS,
            .TRACE => self.TRACE,
        };
    }
};

pub const Endpoint = struct {
    callable: Callable,
    methods: Methods = .{ .GET = true },
};

pub const Match = struct {
    name: []const u8,
    match: union(enum) {
        call: Callable,
        route: Router,
        simple: []const Match,
    },
    methods: Methods = .{ .GET = true },
};

pub fn ROUTE(comptime name: []const u8, comptime match: anytype) Match {
    return comptime Match{
        .name = name,
        .match = switch (@typeInfo(@TypeOf(match))) {
            .Pointer => |ptr| switch (@typeInfo(ptr.child)) {
                .Fn => |fnc| switch (fnc.return_type orelse null) {
                    Error!void => .{ .call = match },
                    Error!Callable => .{ .route = match },
                    else => @compileError("unknown function return type"),
                },
                else => .{ .simple = match },
            },
            .Fn => |fnc| switch (fnc.return_type orelse null) {
                Error!void => .{ .call = match },
                Error!Callable => .{ .route = match },
                else => @compileError("unknown function return type"),
            },
            else => |el| @compileError("match type not supported, for provided type [" ++
                @typeName(@TypeOf(el)) ++
                "]"),
        },

        .methods = .{ .GET = true },
    };
}

pub fn any(comptime name: []const u8, comptime match: Callable) Match {
    var mr = ROUTE(name, match);
    mr.methods = .{ .GET = true, .POST = true };
    return mr;
}

pub fn GET(comptime name: []const u8, comptime match: Callable) Match {
    var mr = ROUTE(name, match);
    mr.methods = .{ .GET = true };
    return mr;
}

pub fn POST(comptime name: []const u8, comptime match: Callable) Match {
    var mr = ROUTE(name, match);
    mr.methods = .{ .POST = true };
    return mr;
}

pub fn STATIC(comptime name: []const u8) Match {
    var mr = ROUTE(name, StaticFile.fileOnDisk);
    mr.methods = .{ .GET = true };
    return mr;
}

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

pub fn router(ctx: *Context, comptime routes: []const Match) Callable {
    const search = ctx.uri.peek() orelse return notfound;
    inline for (routes) |ep| {
        if (eql(search, ep.name)) {
            switch (ep.match) {
                .call => |call| {
                    if (ep.methods.matchMethod(ctx.request.method))
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

const root = [_]Match{
    ROUTE("", default),
};

pub fn baseRouter(ctx: *Context) Error!void {
    //std.debug.print("baserouter {s}\n", .{ctx.uri.peek().?});
    if (ctx.uri.peek()) |first| {
        if (first.len > 0) {
            const route: Callable = router(ctx, &root);
            return route(ctx);
        }
    }
    return default(ctx);
}

const root_with_static = root ++
    [_]Match{.{ .name = "static", .match = .{ .call = StaticFile.file } }};

pub fn baseRouterHtml(ctx: *Context) Error!void {
    //std.debug.print("baserouter {s}\n", .{ctx.uri.peek().?});
    if (ctx.uri.peek()) |first| {
        if (first.len > 0) {
            const route: Callable = router(ctx, &root_with_static);
            return route(ctx);
        }
    }
    return default(ctx);
}
