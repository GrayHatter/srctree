const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();

pub const Tag = @This();

pub const TYPE_PREFIX = "tag";
const READ_VERSION: usize = 0;

pub var datad: std.fs.Dir = undefined;
pub fn init(_: []const u8) !void {}
pub fn initType() !void {}

pub const Kind = enum {
    str,
    owner,
};

pub const Set = struct {
    // TODO decide if a sha hash is actually sane source id
    src: [40]u8,
    tags: []Tag,
};

pub fn readVersioned(a: Allocator, file: std.fs.File, _: [20]u8) !Tag {
    var reader = file.reader();
    const ver: usize = try reader.readInt(usize, endian);
    switch (ver) {
        0 => {
            var local: Tag = undefined;
            if (try reader.read(&local.src) != 20) return error.InvalidFile;
            local.username = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF);
            return Tag{
                .src = local.src,
                .name = local.username,
                .time = try reader.readInt(i64, endian),
            };
        },
        else => return error.UnsupportedVersion,
    }
}

type: []u8,
name: []u8,

pub fn readFile(a: Allocator, file: std.fs.File) !Tag {
    defer file.close();
    return readVersioned(a, file);
}

pub fn raze(self: Tag, a: Allocator) void {
    a.free(self.username);
}

pub fn writeOut(_: Tag) !void {
    unreachable; // not implemented
}

pub fn new() !Tag {
    return error.NotImplemnted;
}

pub fn open(a: Allocator, src: [20]u8) !Tag {
    for (src) |c| if (!std.ascii.isLower(c)) return error.InvalidSrc;

    const ufile = datad.openFile(src, .{}) catch return error.SrcNotFound;
    return try Tag.readFile(a, ufile);
}
