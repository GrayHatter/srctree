const std = @import("std");
const Response = @import("response.zig");

pub const Error = error{
    Unknown,
    AndExit,
    OutOfMemory,
};

pub const Endpoint = *const fn (*Response, []const u8) Error!void;
