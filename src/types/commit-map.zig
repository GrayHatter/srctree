/// This probably should pipe/flow/depend on `git notes` but here we are...
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();

const Delta = @import("delta.zig");

const COMMITMAP_VERSION: usize = 0;
pub const TYPE_PREFIX = "{s}/commitmap";
pub var datad: std.fs.Dir = undefined;

pub fn initType() !void {}

pub fn raze() void {}

const CommitMap = @This();

const Attach = enum(u8) {
    nothing = 0,
    delta = 1,
    _,
};

hash: [40]u8,
created: i64,
updated: i64,
repo: []u8,
attach: union(Attach) {
    nothing: usize,
    delta: usize,
},

file: std.fs.File,

pub fn delta(cm: CommitMap, a: Allocator) !?Delta {
    switch (cm.attach) {
        .nothing => return null,
        .delta => |dlt| {
            return try Delta.open(a, cm.repo, dlt);
        },
        else => unreachable,
    }
}

fn readVersioned(a: Allocator, file: std.fs.File) !CommitMap {
    var reader = file.reader();
    const ver: usize = try reader.readInt(usize, endian);
    return switch (ver) {
        0 => CommitMap{
            .hash = try reader.readBytesNoEof(40),
            .created = try reader.readInt(i64, endian),
            .updated = try reader.readInt(i64, endian),
            .repo = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            //.author = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .attach = switch (@as(Attach, @enumFromInt(try reader.readInt(u8, endian)))) {
                .nothing => .{ .nothing = try reader.readInt(usize, endian) },
                .delta => .{ .delta = try reader.readInt(usize, endian) },
                else => return error.UnsupportedVersion,
            },
            .file = file,
        },
        else => return error.UnsupportedVersion,
    };
}

pub fn writeOut(self: CommitMap) !void {
    try self.file.seekTo(0);
    var writer = self.file.writer();
    try writer.writeInt(usize, COMMITMAP_VERSION, endian);
    try writer.writeAll(self.hash);
    try writer.writeInt(i64, self.created, endian);
    try writer.writeInt(i64, self.updated, endian);
    try writer.writeAll(self.repo);
    try writer.writeAll("\x00");

    try writer.writeInt(u8, @intFromEnum(self.attach), endian);
    switch (self.attach) {
        .nothing => try writer.writeInt(usize, 0, endian),
        .delta => |dlt| try writer.writeInt(usize, dlt, endian),
        else => unreachable,
    }

    try self.file.setEndPos(self.file.getPos() catch unreachable);
}

pub fn new(repo: []const u8, hash: []const u8) !CommitMap {
    // TODO this is probably a bug
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.{x}.cmap", .{ repo, hash });
    const file = try datad.createFile(filename, .{});

    const cm = CommitMap{
        .hash = hash[0..40].*,
        .created = std.time.timestamp(),
        .updated = std.time.timestamp(),
        .repo = repo,
        .file = file,
    };

    return cm;
}

pub fn open(a: Allocator, repo: []const u8, hash: []const u8) !CommitMap {
    // FIXME buffer overrun when repo is malicious
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.{x}.cmap", .{ repo, hash });
    const file = datad.openFile(filename, .{ .mode = .read_write }) catch return error.Other;
    return try CommitMap.readVersioned(a, file);
}
