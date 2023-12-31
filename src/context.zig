pub const std = @import("std");

const Allocator = std.mem.Allocator;

const zWSGI = @import("zwsgi.zig");
const Auth = @import("auth.zig");

const zWSGIRequest = zWSGI.zWSGIRequest;

pub const Request = @import("request.zig");
pub const Response = @import("response.zig");
pub const UserData = @import("user-data.zig").UserData;
pub const Template = @import("template.zig");
pub const UriIter = @import("endpoint.zig").Router.UriIter;

pub const Context = @This();

alloc: Allocator,
request: Request,
response: Response,
usr_data: UserData,
uri: UriIter,
auth: Auth,
// TODO fix this API
template_ctx: Template.Context,

const VarPair = struct {
    []const u8,
    []const u8,
};

pub fn init(a: Allocator, req: Request, res: Response, usr_data: UserData) !Context {
    std.debug.assert(req.uri[0] == '/');
    //const reqheader = req.headers
    return Context{
        .alloc = a,
        .request = req,
        .response = res,
        .usr_data = usr_data,
        .uri = std.mem.split(u8, req.uri[1..], "/"),
        .auth = Auth.init(req.headers),
        .template_ctx = Template.Context.init(a),
    };
}

/// TODO rename plz
pub fn addRouteVar(ctx: *Context, name: []const u8, val: []const u8) !void {
    try ctx.template_ctx.put(name, val);
}

/// TODO fix these unreachable, currently debugging
pub fn sendTemplate(ctx: *Context, t: *Template.Template) !void {
    ctx.response.start() catch unreachable;
    //
    const loggedin = if (ctx.request.auth.valid()) "<a href=\"#\">Logged In</a>" else "Public";
    try t.addVar("header.auth", loggedin);
    if (ctx.request.auth.user(ctx.alloc)) |usr| {
        try t.addVar("current_username", usr.username);
    } else |_| {}
    //
    const page = try t.buildFor(ctx.alloc, ctx.template_ctx);
    defer ctx.alloc.free(page);
    ctx.response.send(page) catch unreachable;
    ctx.response.finish() catch unreachable;
}
