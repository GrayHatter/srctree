const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Networks = @This();

const NET_VERSION: usize = 0;

pub const Network = struct {
    name: []u8,
    location: []u8,
    highlight: u8,

    file: std.fs.File,

    pub fn writeOut(self: Network) !void {
        try self.file.seekTo(0);
        const w = self.file.writer();
        try w.writeIntNative(usize, NET_VERSION);
        try w.writeAll(self.name);
        try w.writeAll("\x00");
        try w.writeAll(self.uri);
        try w.writeAll("\x00");
        try w.writeIntNative(u8, self.highlight);
    }
};

var datad: std.fs.Dir = undefined;

pub fn init(dir: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}/networks", .{dir});
    datad = try std.fs.cwd().openDir(filename, .{});
}

pub fn raze() void {
    datad.close();
}
