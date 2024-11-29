const std = @import("std");
const eql = std.mem.eql;

const Allocator = std.mem.Allocator;

const api = @import("api.zig");
const Verse = @import("verse.zig");
const Response = @import("response.zig");
const Request = @import("request.zig");
const HTML = @import("html.zig");
const StaticFile = @import("static-file.zig");

pub const Errors = @import("errors.zig");
pub const Error = Errors.ServerError || Errors.ClientError || Errors.NetworkError;

pub const UriIter = std.mem.SplitIterator(u8, .scalar);

pub const Router = *const fn (*Verse) Error!Callable;
pub const Callable = *const fn (*Verse) Error!void;

pub const DEBUG: bool = false;

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

        .methods = .{ .GET = true, .POST = true },
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

pub fn defaultResponse(comptime code: std.http.Status) Callable {
    return switch (code) {
        .not_found => notFound,
        .internal_server_error => internalServerError,
        else => default,
    };
}

fn notFound(ctx: *Verse) Error!void {
    ctx.response.status = .not_found;
    const E4XX = @embedFile("../templates/4XX.html");
    return ctx.sendRawSlice(E4XX);
}

fn internalServerError(ctx: *Verse) Error!void {
    ctx.response.status = .internal_server_error;
    const E5XX = @embedFile("../templates/5XX.html");
    return ctx.sendRawSlice(E5XX);
}

fn default(ctx: *Verse) Error!void {
    const index = @embedFile("../templates/index.html");
    return ctx.sendRawSlice(index);
}

pub fn router(ctx: *Verse, comptime routes: []const Match) Callable {
    const search = ctx.uri.peek() orelse {
        if (DEBUG) std.debug.print("No endpoint found: URI is empty.\n", .{});
        return notFound;
    };
    inline for (routes) |ep| {
        if (eql(u8, search, ep.name)) {
            switch (ep.match) {
                .call => |call| {
                    if (ep.methods.matchMethod(ctx.request.method))
                        return call;
                },
                .route => |route| {
                    return route(ctx) catch |err| switch (err) {
                        error.Unrouteable => return notFound,
                        else => unreachable,
                    };
                },
                .simple => |simple| {
                    _ = ctx.uri.next();
                    if (ctx.uri.peek() == null and
                        eql(u8, simple[0].name, "") and
                        simple[0].match == .call)
                        return simple[0].match.call;
                    return router(ctx, simple);
                },
            }
        }
    }
    return notFound;
}

const root = [_]Match{
    ROUTE("", default),
};

pub fn baseRouter(ctx: *Verse) Error!void {
    if (DEBUG) std.debug.print("baserouter {s}\n", .{ctx.uri.peek().?});
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

pub fn baseRouterHtml(ctx: *Verse) Error!void {
    if (DEBUG) std.debug.print("baserouter {s}\n", .{ctx.uri.peek().?});
    if (ctx.uri.peek()) |first| {
        if (first.len > 0) {
            const route: Callable = router(ctx, &root_with_static);
            return route(ctx);
        }
    }
    return default(ctx);
}
