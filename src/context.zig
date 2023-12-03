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
    };
}

pub fn sendTemplate(ctx: *Context, t: *Template) !void {
    try ctx.response.start();
    const page = try t.buildFor(ctx.alloc, ctx);
    try ctx.response.send(page);
    try ctx.response.finish();
}
