const std = @import("std");

const Allocator = std.mem.Allocator;

const Template = @import("template.zig");
const Context = @import("context.zig");
const Response = @import("response.zig");
const Request = @import("request.zig");
const endpoint = @import("endpoint.zig");
const HTML = @import("html.zig");

const Endpoint = endpoint.Endpoint;
const Error = endpoint.Error;
pub const UriIter = std.mem.SplitIterator(u8, .sequence);

const div = HTML.div;
const span = HTML.span;

pub const Router = *const fn (*Context) Error!Endpoint;

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
    .{ .name = "admin", .match = .{ .route = endpoint.admin } },
    .{ .name = "auth", .match = .{ .call = auth } },
    .{ .name = "bye", .match = .{ .call = bye } },
    .{ .name = "commits", .match = .{ .call = respond } },
    .{ .name = "hi", .match = .{ .call = respond } },
    .{ .name = "post", .match = .{ .call = post } },
    .{ .name = "repo", .match = .{ .route = endpoint.repo } },
    .{ .name = "repos", .match = .{ .route = endpoint.repo } },
    .{ .name = "tree", .match = .{ .call = respond } },
    .{ .name = "user", .match = .{ .call = endpoint.commitFlex } },
};

fn sendMsg(r: *Response, msg: []const u8) !void {
    //r.transfer_encoding = .{ .content_length = msg.len };
    try r.start();
    try r.send(msg);
    try r.finish();
}

fn bye(r: *Response, _: *UriIter) Error!void {
    const MSG = "bye!\n";
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
    };
    return Error.AndExit;
}

fn auth(r: *Response, _: *UriIter) Error!void {
    std.debug.print("auth is {}\n", .{r.request.auth});
    if (r.request.auth.valid()) {
        r.status = .ok;
        sendMsg(r, "Oh hi! Welcome back\n") catch |e| {
            std.log.err("Auth Failed somehow [{}]\n", .{e});
            return Error.AndExit;
        };
        return;
    }
    r.status = .forbidden;
    sendMsg(r, "Kindly Shoo!\n") catch |e| {
        std.log.err("Auth Failed somehow [{}]\n", .{e});
        return Error.AndExit;
    };
}

fn notfound(r: *Response, _: *UriIter) Error!void {
    r.status = .not_found;
    const MSG = Template.find("index.html").blob;
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
        return Error.AndExit;
    };
}

fn respond(r: *Response, _: *UriIter) Error!void {
    r.headersAdd("connection", "keep-alive") catch return Error.ReqResInvalid;
    r.headersAdd("content-type", "text/plain") catch return Error.ReqResInvalid;
    const MSG = "Hi, mom!\n";
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
        return Error.AndExit;
    };
}

fn default(r: *Response, _: *UriIter) Error!void {
    const MSG = Template.find("index.html").blob;
    sendMsg(r, MSG) catch |e| switch (e) {
        error.NotWriteable => unreachable,
        else => {
            std.log.err("Unexpected error while responding [{}]\n", .{e});
            return Error.AndExit;
        },
    };
}

fn post(r: *Response, _: *UriIter) Error!void {
    const MSG = Template.find("post.html").blob;
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
        return Error.AndExit;
    };
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
            return route(&ctx.response, &ctx.uri);
        }
    }
    return default(&ctx.response, &ctx.uri);
}
