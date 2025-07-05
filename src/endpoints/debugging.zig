pub const verse_name = .debugging;

pub const verse_endpoint_enabled: bool = builtin.mode == .Debug;

pub const verse_routes = [_]Route.Match{
    Route.ANY("400", _400),
    Route.ANY("401", _401),
    Route.ANY("403", _403),
    Route.ANY("404", _404),
    Route.ANY("500", _500),
};

pub fn _400(f: *Frame) !void {
    return f.sendDefaultErrorPage(.bad_request);
}

pub fn _401(f: *Frame) !void {
    return f.sendDefaultErrorPage(.unauthorized);
}

pub fn _403(f: *Frame) !void {
    return f.sendDefaultErrorPage(.forbidden);
}

pub fn _404(f: *Frame) !void {
    return f.sendDefaultErrorPage(.not_found);
}

pub fn _500(f: *Frame) !void {
    return f.sendDefaultErrorPage(.internal_server_error);
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const verse = @import("verse");
const Frame = verse.Frame;
const Route = verse.Router;
const template = verse.template;
const HTML = template.html;
const DOM = HTML.DOM;

const Error = Route.Error;

const git = @import("../git.zig");
