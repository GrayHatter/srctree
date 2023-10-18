const std = @import("std");

pub const HTML = @import("html.zig");
pub const Response = @import("response.zig");
pub const Template = @import("template.zig");

pub const Error = error{
    Unknown,
    ReqResInvalid,
    AndExit,
    OutOfMemory,
};

pub const Endpoint = *const fn (*Response, []const u8) Error!void;

pub const commitFlex = @import("endpoints/commit-flex.zig").commitFlex;
