const std = @import("std");
const Server = std.http.Server;

pub const Error = error{
    Unknown,
    AndExit,
    OutOfMemory,
};

pub const Endpoint = *const fn (*Server.Response, []const u8) Error!void;
