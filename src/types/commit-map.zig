repo: []u8,
hexsha: []u8,
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

pub fn new(repo: []const u8, sha: *const git.Sha, io: Io) !CommitMap {
    var cm = CommitMap{
        .repo = repo,
        .hexsha = sha,
        .created = std.time.timestamp(),
        .updated = std.time.timestamp(),
        .attach_to = .nothing,
        .attach_target = 0,
    };
    cm.commit(io);
    return cm;
}

pub fn open(repo: []const u8, sha: git.Sha, a: Allocator, io: Io) !CommitMap {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.{f}.cmtmap", .{ repo, std.fmt.alt(sha, .fmtHex) });
    var reader = try Types.loadDataReader(.commit_map, filename, a, io);
    return readerFn(&reader);
}

pub fn commit(cm: *CommitMap, io: Io) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.{f}.cmtmap", .{ cm.repo, cm.hexsha });
    const file = try Types.commit(.commit_map, filename, io);
    defer file.close(io);
    var writer = file.writer(io, &.{});
    try writerFn(cm, &writer);
}

const typeio = Types.readerWriter(CommitMap, .{ .repo = &.{}, .hexsha = &.{} });
const writerFn = typeio.write;
const readerFn = typeio.read;

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Types = @import("../types.zig");
const git = @import("../git.zig");
