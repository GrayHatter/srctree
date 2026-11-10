type: []u8,
name: []u8,

const Tag = @This();

pub const type_prefix = .messages;
pub const type_version = 0;

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

pub fn open(_: Allocator, _: [20]u8) !Tag {
    comptime unreachable;
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();
