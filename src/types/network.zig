const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Network = @This();

pub const TYPE_PREFIX = "{s}/networks";
const NETWORK_VERSION: usize = 0;
pub var datad: std.fs.Dir = undefined;

pub fn init(_: []const u8) !void {}
pub fn initType() !void {}

name: []u8,
location: []u8,
highlight: u8,

file: std.fs.File,

pub fn writeOut(self: Network) !void {
    try self.file.seekTo(0);
    const w = self.file.writer();
    try w.writeIntNative(usize, NETWORK_VERSION);
    try w.writeAll(self.name);
    try w.writeAll("\x00");
    try w.writeAll(self.uri);
    try w.writeAll("\x00");
    try w.writeIntNative(u8, self.highlight);
}

pub fn validName(name: []const u8) bool {
    for (name) |c| switch (c) {
        'a'...'z' => continue,
        else => return false,
    } else return true;
}

/// TODO actually allow real URIs, and check if the network location exists :D
pub fn validLocation(loc: []const u8) bool {
    return validName(loc);
}

pub fn new(name: []const u8, loc: []const u8, hl: bool) !Network {
    if (!validName(name) or !validLocation(loc)) return error.InvalidNetwork;
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.network", .{name});
    const file = try datad.createFile(filename, .{});
    var nw = Network{
        .name = name,
        .location = loc,
        .highlight = if (hl) 1 else 0,
        .file = file,
    };
    try nw.writeOut();
    return nw;
}
