const std = @import("std");

pub const HTML = @import("html.zig");
pub const DOM = @import("dom.zig");
pub const Response = @import("response.zig");
pub const Request = @import("request.zig");
pub const Template = @import("template.zig");
pub const Router = @import("routes.zig");

pub const UriIter = Router.UriIter;

pub const Error = error{
    Unknown,
    ReqResInvalid,
    AndExit,
    OutOfMemory,
    Unrouteable,
    InvalidURI,

    Abusive,
};

pub const router = Router.router;

pub const Endpoint = *const fn (*Response, *Router.UriIter) Error!void;

pub const commitFlex = @import("endpoints/commit-flex.zig").commitFlex;

pub const REPO = @import("endpoints/repos.zig");
pub const repo = REPO.router;
