pub const std = @import("std");

const Allocator = std.mem.Allocator;

const zWSGI = @import("zwsgi.zig");
const Auth = @import("auth.zig");
const Request = @import("request.zig");
const Response = @import("response.zig");

const zWSGIRequest = zWSGI.zWSGIRequest;

pub const Context = @This();

alloc: Allocator,
request: Request,
response: Response,
auth: Auth,

pub fn init(a: Allocator, req: Request, res: Response) !Context {
    return Context{
        .alloc = a,
        .request = req,
        .response = res,
        .auth = Auth.init(&req.headers),
    };
}
