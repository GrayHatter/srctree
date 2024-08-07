const std = @import("std");

pub const HTML = @import("html.zig");
pub const DOM = @import("dom.zig");
pub const Context = @import("context.zig");
//pub const Response = @import("response.zig");
//pub const Request = @import("request.zig");
pub const Template = @import("template.zig");
pub const Router = @import("routes.zig");
pub const Types = @import("types.zig");
pub const Callable = Router.Callable;

pub const Errors = @import("errors.zig");

pub const Error = Errors.ServerError || Errors.ClientError || Errors.NetworkError;

pub const router = Router.router;

pub const commitFlex = @import("endpoints/commit-flex.zig").commitFlex;

pub const USERS = @import("endpoints/users.zig");

pub const REPO = @import("endpoints/repos.zig");
pub const repo = REPO.router;

pub const ADMIN = @import("endpoints/admin.zig");
pub const admin = &ADMIN.endpoints;

pub const NETWORK = @import("endpoints/network.zig");
pub const network = &NETWORK.endpoints;

pub const SEARCH = @import("endpoints/search.zig");
pub const search = &SEARCH.router;
