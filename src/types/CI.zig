index: usize,
created: i64 = 0,
repo: []const u8,
reason: []const u8,
source: []const u8,
result: Result = .unknown,
thread_id: usize = 0,
commit_hash: Hash = @splat(0),

steps: ArrayList(Step) = .{},

pub const CI = @This();
pub const Hash = Types.Sha1Bin;

pub const Result = enum(u8) {
    unknown,
    pending,
    waiting,
    started,
    running,
    stalled,
    passed,
    failed,
    @"error",
};

pub const Step = struct {
    result: Result = .unknown,
    payload: []const u8 = &.{},
};

pub const type_prefix = .continuous_integration;
pub const type_version = 0;

const typeio = Types.readerWriter(CI, .{
    .index = 0,
    .repo = &.{},
    .reason = &.{},
    .source = &.{},
});
const writerFn = typeio.write;
const readerFn = typeio.read;
const Index = Types.Index(type_prefix);
const fmt_str = "{s}.{x}." ++ @tagName(type_prefix);

pub fn new(repo: []const u8, reason: []const u8, source: []const u8, result: Result, commit_hash: Hash, io: Io) !CI {
    const max: usize = try Index.nextExtra(repo, io);
    const now = Io.Clock.real.now(io).toSeconds();
    var ci = CI{
        .index = max,
        .created = now,
        .repo = repo,
        .reason = reason,
        .source = source,
        .result = result,
        .commit_hash = commit_hash,
    };
    try ci.commit(io);
    return ci;
}

pub fn open(repo: []const u8, index: usize, a: Allocator, io: Io) !CI {
    const max = Index.currentExtra(repo, io) catch return error.FSFault;
    if (index > max) return error.CIDoesNotExist;

    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, fmt_str, .{ repo, index });
    var reader = Types.loadDataReader(type_prefix, filename, a, io) catch return error.FSFault;
    return readerFn(&reader);
}

pub fn commit(ci: CI, io: Io) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, fmt_str, .{ ci.repo, ci.index });
    const file = try Types.commit(type_prefix, filename, io);
    defer file.close(io);
    var w_b: [2048]u8 = undefined;
    var fd_writer = file.writer(io, &w_b);
    try writerFn(&ci, &fd_writer.interface);
}

pub const Comment = struct {
    author: []const u8,
    message: []const u8,
};

test CI {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init(try tempdir.dir.createDirPathOpen(io, "continuous_integration", .{ .open_options = .{ .iterate = true } }), io);

    var ci = try CI.new("repo_name", "reason", "source", .@"error", @splat('z'), io);

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0x7ffffff);
    ci.created = Io.Clock.real.now(io).toSeconds() & mask;

    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try writerFn(&ci, &writer.writer);

    const v1_text: []const u8 =
        \\# continuous_integration/0
        \\index: 1
        \\created: 1744830464
        \\repo: repo_name
        \\reason: reason
        \\source: source
        \\result: error
        \\thread_id: 0
        \\commit_hash: 7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a
        \\
        \\
    ;

    try std.testing.expectEqualStrings(v1_text, writer.written());

    var r: Io.Reader = .fixed(writer.written());
    const read = readerFn(&r);
    try std.testing.expectEqualDeep(ci, read);
}

const std = @import("std");
const log = std.log.scoped(.srctree_type_ci);
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const bufPrint = std.fmt.bufPrint;

const Types = @import("../types.zig");
