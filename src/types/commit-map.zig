repo: []u8,
hexsha: [40]u8,
created: i64 = 0,
updated: i64 = 0,
attach_to: Attach = .nothing,
attach_target: usize = 0,

pub const type_version: usize = 0;
pub const type_prefix = "commit-map";

const CommitMap = @This();

const Attach = enum(u8) {
    nothing = 0,
    delta = 1,
};

pub fn new(repo: []const u8, hexsha: [40]u8) !CommitMap {
    var cm = CommitMap{
        .repo = repo,
        .hexsha = hexsha,
        .created = std.time.timestamp(),
        .updated = std.time.timestamp(),
        .attach_to = .nothing,
        .attach_target = 0,
    };
    cm.commit();
    return cm;
}

pub fn open(repo: []const u8, hexsha: [40]u8, a: Allocator, io: Io) !CommitMap {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.{x}.cmtmap", .{ repo, hexsha });
    var reader = try Types.loadDataReader(.commit_map, filename, a, io);
    return readerFn(&reader.interface);
}

pub fn commit(cm: *CommitMap, io: Io) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.{x}.cmtmap", .{ cm.repo, cm.hexsha });
    const file = try Types.commit(.commit_map, filename, io);
    defer file.close();
    var writer = file.writer();
    try writerFn(cm, &writer);
}

const typeio = Types.readerWriter(CommitMap, .{ .repo = &.{}, .hexsha = @splat(0) });
const writerFn = typeio.write;
const readerFn = typeio.read;

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const endian = builtin.cpu.arch.endian();
const Types = @import("../types.zig");
