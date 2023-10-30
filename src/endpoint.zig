const std = @import("std");

pub const HTML = @import("html.zig");
pub const DOM = @import("dom.zig");
pub const Response = @import("response.zig");
pub const Template = @import("template.zig");

pub const Error = error{
    Unknown,
    ReqResInvalid,
    AndExit,
    OutOfMemory,
    Unrouteable,
};

pub const Endpoint = *const fn (*Response, []const u8) Error!void;

pub const commitFlex = @import("endpoints/commit-flex.zig").commitFlex;

pub const code = @import("endpoints/source-view.zig").code;

pub const REPO = @import("endpoints/repos.zig");
pub const repo = REPO.router;
