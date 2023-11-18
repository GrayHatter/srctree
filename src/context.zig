pub const std = @import("std");

const Allocator = std.mem.Allocator;

const zWSGI = @import("zwsgi.zig");
const Auth = @import("auth.zig");

const zWSGIRequest = zWSGI.zWSGIRequest;

pub const Request = @import("request.zig");
pub const Response = @import("response.zig");
pub const HttpPost = @import("http-post.zig");
pub const UriIter = @import("endpoint.zig").Router.UriIter;

pub const Context = @This();

alloc: Allocator,
request: Request,
response: Response,
post_data: HttpPost.PostData,
uri: UriIter,
auth: Auth,

pub fn init(a: Allocator, req: Request, res: Response, post_data: HttpPost.PostData) !Context {
    std.debug.assert(req.uri[0] == '/');
    //const reqheader = req.headers
    return Context{
        .alloc = a,
        .request = req,
        .response = res,
        .post_data = post_data,
        .uri = std.mem.split(u8, req.uri[1..], "/"),
        .auth = Auth.init(req.headers),
    };
}
