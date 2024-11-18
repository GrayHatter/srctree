const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();

const Types = @import("../types.zig");

pub const Read = @This();

pub const TYPE_PREFIX = "read";
const READ_VERSION: usize = 0;

var datad: std.fs.Dir = undefined;
pub fn init(_: []const u8) !void {}
pub fn initType(stor: Types.Storage) !void {
    datad = stor;
}

pub fn readVersioned(a: Allocator, file: std.fs.File, _: [20]u8) !Read {
    var reader = file.reader();
    const ver: usize = try reader.readInt(usize, endian);
    switch (ver) {
        0 => {
            var local: Read = undefined;
            if (try reader.read(&local.src) != 20) return error.InvalidFile;
            local.username = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF);
            return Read{
                .src = local.src,
                .username = local.username,
                .time = try reader.readInt(i64, endian),
            };
        },
        else => return error.UnsupportedVersion,
    }
}

src: [20]u8 = .{0} ** 20,
username: []u8,
time: i64,

pub fn readFile(a: Allocator, file: std.fs.File) !Read {
    defer file.close();
    return readVersioned(a, file);
}

pub fn raze(self: Read, a: Allocator) void {
    a.free(self.username);
}

pub fn writeOut(_: Read) !void {
    unreachable; // not implemented
}

pub fn new() !Read {
    return error.NotImplemnted;
}

pub fn open(a: Allocator, src: [20]u8) !Read {
    for (src) |c| if (!std.ascii.isLower(c)) return error.InvalidSrc;

    const ufile = datad.openFile(src, .{}) catch return error.SrcNotFound;
    return try Read.readFile(a, ufile);
}
