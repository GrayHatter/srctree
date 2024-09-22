pub const std = @import("std");

const Allocator = std.mem.Allocator;

const zWSGI = @import("zwsgi.zig");
const Auth = @import("auth.zig");

const zWSGIRequest = zWSGI.zWSGIRequest;

pub const Request = @import("request.zig");
pub const Response = @import("response.zig");
pub const RequestData = @import("request_data.zig").RequestData;
pub const Template = @import("template.zig");
pub const UriIter = @import("endpoint.zig").Router.UriIter;
const Config = @import("ini.zig").Config;

const Error = @import("errors.zig").Error;

pub const Context = @This();

alloc: Allocator,
request: Request,
response: Response,
req_data: RequestData,
uri: UriIter,
cfg: ?Config,

// TODO fix this unstable API
auth: Auth,
template_ctx: Template.Context,
route_ctx: ?*const anyopaque = null,

const VarPair = struct {
    []const u8,
    []const u8,
};

pub fn init(a: Allocator, cfg: ?Config, req: Request, res: Response, req_data: RequestData) !Context {
    std.debug.assert(req.uri[0] == '/');
    //const reqheader = req.headers
    return Context{
        .alloc = a,
        .request = req,
        .response = res,
        .req_data = req_data,
        .uri = std.mem.split(u8, req.uri[1..], "/"),
        .cfg = cfg,
        .auth = Auth.init(req.headers),
        .template_ctx = Template.Context.init(a),
    };
}

const HTML = @import("html.zig");

/// TODO Remove thes    /// caller owns of the returned slice, freeing the data before the final use is undefined
pub fn addElements(ctx: *Context, a: Allocator, name: []const u8, els: []const HTML.Element) !void {
    return ctx.addElementsFmt(a, "{}", name, els);
}

/// caller owns of the returned slice, freeing the data before the final use is undefined
pub fn addElementsFmt(
    ctx: *Context,
    a: Allocator,
    comptime fmt: []const u8,
    name: []const u8,
    els: []const HTML.Element,
) !void {
    const list = try a.alloc([]u8, els.len);
    defer a.free(list);
    for (list, els) |*l, e| {
        l.* = try std.fmt.allocPrint(a, fmt, .{e});
    }
    defer {
        for (list) |l| a.free(l);
    }
    const value = try std.mem.join(a, "", list);

    // TODO FIXME plz
    try ctx.template_ctx.put(name, .{ .slice = value });
}

pub fn putContext(ctx: *Context, name: []const u8, val: Template.Context.Data) !void {
    ctx.template_ctx.put(name, val) catch |err| switch (err) {
        error.OutOfMemory => return err,
    };
}

/// Kept for compat, please use putContext
pub fn addRouteVar(ctx: *Context, name: []const u8, val: []const u8) !void {
    try ctx.putContext(name, .{ .slice = val });
}

/// TODO fix these unreachable, currently debugging
pub fn sendTemplate(ctx: *Context, t: *Template.Template) Error!void {
    ctx.response.start() catch |err| switch (err) {
        error.BrokenPipe => return error.NetworkCrash,
        else => unreachable,
    };
    const loggedin = if (ctx.request.auth.valid()) "<a href=\"#\">Logged In</a>" else "Public";
    try ctx.putContext("Header.auth", .{ .slice = loggedin });
    if (ctx.request.auth.user(ctx.alloc)) |usr| {
        try ctx.putContext("Current_username", .{ .slice = usr.username });
    } else |_| {}
    //
    const page = try t.buildFor(ctx.alloc, ctx.template_ctx);
    defer ctx.alloc.free(page);
    ctx.response.send(page) catch unreachable;
    ctx.response.finish() catch unreachable;
}

pub fn sendJSON(ctx: *Context, json: anytype) Error!void {
    ctx.response.start() catch |err| switch (err) {
        error.BrokenPipe => return error.NetworkCrash,
        else => unreachable,
    };

    const data = std.json.stringifyAlloc(ctx.alloc, json, .{}) catch |err| {
        std.debug.print("Error trying to print json {}\n", .{err});
        return error.Unknown;
    };
    ctx.response.writeAll(data) catch unreachable;
    ctx.response.finish() catch unreachable;
}
