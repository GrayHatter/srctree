const std = @import("std");

pub const HTML = @import("html.zig");
pub const DOM = @import("dom.zig");
pub const Response = @import("response.zig");
pub const Request = @import("request.zig");
pub const Template = @import("template.zig");
pub const Router = @import("routes.zig");

pub const UriIter = Router.UriIter;

pub const Error = ServerError || ClientError;

pub const ServerError = error{
    AndExit,
    OutOfMemory,
    ReqResInvalid,
    Unknown,
};

pub const ClientError = error{
    Abusive,
    BadData,
    DataMissing,
    InvalidURI,
    Unauthenticated,
    Unrouteable,
};

pub const router = Router.router;

pub const Endpoint = *const fn (*Response, *Router.UriIter) Error!void;

pub const commitFlex = @import("endpoints/commit-flex.zig").commitFlex;

pub const TODO = @import("endpoints/todo.zig");
pub const todo = &TODO.endpoints;

pub const REPO = @import("endpoints/repos.zig");
pub const repo = REPO.router;

pub const ADMIN = @import("endpoints/admin.zig");
pub const admin = &ADMIN.endpoints;

pub const NETWORK = @import("endpoints/network.zig");
pub const network = &NETWORK.endpoints;
