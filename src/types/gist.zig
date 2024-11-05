const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Gist = @This();

pub const TYPE_PREFIX = "{s}/gist";
const GIST_VERSION: usize = 0;
pub var datad: std.fs.Dir = undefined;

pub const File = struct {
    name: []const u8,
    blob: []const u8,
};

hash: [32]u8,
owner: []const u8,
created: i64,
files: []const File,

pub fn init(_: []const u8) !void {}
pub fn initType() !void {}

fn readVersioned(a: Allocator, hash: [32]u8, reader: std.io.AnyReader) !Gist {
    const int: usize = try reader.readInt(usize, endian);
    return switch (int) {
        0 => {
            const owner = try reader.readUntilDelimiterAlloc(a, 0x00, 0x100);
            const created = try reader.readInt(i64, endian);
            const files = try a.alloc(File, try reader.readInt(u8, endian));
            for (files) |*file| {
                file.name = try reader.readUntilDelimiterAlloc(a, 0x00, 0xFFF);
                file.blob = try reader.readUntilDelimiterAlloc(a, 0x00, 0xFFFF);
            }

            return Gist{
                .hash = hash,
                .owner = owner,
                .created = created,
                .files = files,
            };
        },

        else => error.UnsupportedVersion,
    };
}

pub fn writeOut(self: Gist, w: std.io.AnyWriter) !void {
    try w.writeInt(usize, GIST_VERSION, endian);
    try w.writeAll(self.owner);
    try w.writeAll("\x00");
    try w.writeInt(i64, self.created, endian);
    try w.writeInt(u8, @truncate(self.files.len), endian);
    for (self.files) |file| {
        try w.writeAll(file.name);
        try w.writeAll("\x00");
        try w.writeAll(file.blob);
        try w.writeAll("\x00");
    }
}

pub fn open(a: Allocator, hash: [64]u8) !Gist {
    // TODO handle open errors
    var file = try datad.openFile(hash ++ ".gist", .{});
    defer file.close();

    const reader = file.reader().any();
    var buf: [32]u8 = undefined;
    const hashbytes = try std.fmt.hexToBytes(&buf, &hash);
    return readVersioned(a, hashbytes[0..32].*, reader);
}

pub fn new(owner: []const u8, files: []const File) ![64]u8 {
    var hash: [32]u8 = undefined;
    var hash_str: [64]u8 = undefined;
    var sha = Sha256.init(.{});
    sha.update(owner);
    const created = std.time.timestamp();
    sha.update(std.mem.asBytes(&created));

    for (files) |file| {
        // TODO sanitize file.name
        if (file.name.len == 0) return error.InvalidFilename;
        sha.update(file.name);
        sha.update(file.blob);
    }
    sha.final(&hash);

    const gist = Gist{
        .hash = hash,
        .owner = owner,
        .created = created,
        .files = files,
    };
    _ = try std.fmt.bufPrint(&hash_str, "{}", .{std.fmt.fmtSliceHexLower(&hash)});

    var buf: [67]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.gist", .{hash_str});
    const file = try datad.createFile(filename, .{});
    const writer = file.writer().any();

    try gist.writeOut(writer);

    return hash_str;
}
