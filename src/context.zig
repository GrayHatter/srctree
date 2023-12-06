pub const std = @import("std");

const Allocator = std.mem.Allocator;

const zWSGI = @import("zwsgi.zig");
const Auth = @import("auth.zig");

const zWSGIRequest = zWSGI.zWSGIRequest;

pub const Request = @import("request.zig");
pub const Response = @import("response.zig");
pub const UserData = @import("user-data.zig").UserData;
pub const Template = @import("template.zig").Template;
pub const UriIter = @import("endpoint.zig").Router.UriIter;

pub const Context = @This();

alloc: Allocator,
request: Request,
response: Response,
usr_data: UserData,
uri: UriIter,
auth: Auth,
// TODO fix this API
parent_vars: std.ArrayList(VarPair),

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
        .parent_vars = std.ArrayList(VarPair).init(a),
    };
}

pub fn addRouteVar(ctx: *Context, name: []const u8, val: []const u8) !void {
    try ctx.parent_vars.append(.{ name, val });
}

pub fn sendTemplate(ctx: *Context, t: *Template) !void {
    try ctx.response.start();
    for (ctx.parent_vars.items) |itm| {
        try t.addVar(itm[0], itm[1]);
    }
    const page = try t.buildFor(ctx.alloc, ctx);
    defer ctx.alloc.free(page);
    try ctx.response.send(page);
    try ctx.response.finish();
}
