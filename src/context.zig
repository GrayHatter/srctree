pub const std = @import("std");
const Allocator = std.mem.Allocator;
const splitScalar = std.mem.splitScalar;

const zWSGI = @import("zwsgi.zig");
const Auth = @import("auth.zig");

const zWSGIRequest = zWSGI.zWSGIRequest;

pub const Request = @import("request.zig");
pub const Response = @import("response.zig");
pub const RequestData = @import("request_data.zig");
pub const Template = @import("template.zig");
pub const Routes = @import("routes.zig");
pub const UriIter = Routes.UriIter;
const Config = @import("ini.zig").Config;

const Error = @import("errors.zig").Error;

pub const Context = @This();

alloc: Allocator,
request: Request,
response: Response,
reqdata: RequestData,
uri: UriIter,
cfg: ?Config,

// TODO fix this unstable API
auth: Auth,
route_ctx: ?*const anyopaque = null,

const VarPair = struct {
    []const u8,
    []const u8,
};

pub fn init(a: Allocator, cfg: ?Config, req: Request, res: Response, reqdata: RequestData) !Context {
    std.debug.assert(req.uri[0] == '/');
    //const reqheader = req.headers
    return Context{
        .alloc = a,
        .request = req,
        .response = res,
        .reqdata = reqdata,
        .uri = splitScalar(u8, req.uri[1..], '/'),
        .cfg = cfg,
        .auth = Auth.init(req.headers),
    };
}

pub fn sendPage(ctx: *Context, page: anytype) Error!void {
    ctx.response.start() catch |err| switch (err) {
        error.BrokenPipe => return error.NetworkCrash,
        else => unreachable,
    };
    const loggedin = if (ctx.request.auth.valid()) "<a href=\"#\">Logged In</a>" else "Public";
    const T = @TypeOf(page.*);
    if (@hasField(T, "data") and @hasField(@TypeOf(page.data), "body_header")) {
        page.data.body_header.?.nav.?.nav_auth = loggedin;
    }

    const writer = ctx.response.writer();
    page.format("{}", .{}, writer) catch |err| switch (err) {
        else => std.debug.print("Page Build Error {}\n", .{err}),
    };
}

pub fn sendRawSlice(ctx: *Context, slice: []const u8) Error!void {
    ctx.response.send(slice) catch unreachable;
}

pub fn sendError(ctx: *Context, comptime code: std.http.Status) Error!void {
    return Routes.defaultResponse(code)(ctx);
}

pub fn sendJSON(ctx: *Context, json: anytype) Error!void {
    ctx.response.start() catch |err| switch (err) {
        error.BrokenPipe => return error.NetworkCrash,
        else => unreachable,
    };

    const data = std.json.stringifyAlloc(ctx.alloc, json, .{
        .emit_null_optional_fields = false,
    }) catch |err| {
        std.debug.print("Error trying to print json {}\n", .{err});
        return error.Unknown;
    };
    ctx.response.writeAll(data) catch unreachable;
    ctx.response.finish() catch unreachable;
}
