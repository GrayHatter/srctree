index: usize,
created: types.Timestamp = 0,
updated: types.Timestamp = 0,
repo: []const u8,
hash: Hash = @splat(0),
revision: usize = 0,
trigger: []const u8 = &.{},
result: Result = .unknown,
thread_id: usize = 0,

thread: ?*Thread = null,
steps: ArrayList(Step) = .empty,

pub const CI = @This();
pub const Hash = types.DefaultHash;

pub const Result = enum(u8) {
    unknown,
    pending,
    waiting,
    started,
    running,
    stalled,
    passed,
    failed,
    err,
};

pub const Step = struct {
    result: Result = .unknown,
    payload: []const u8 = &.{},
};

pub const type_prefix = .continuous_integration;
pub const type_version = 0;

const typeio = types.readerWriter(CI, .{
    .index = 0,
    .repo = &.{},
});
const writerFn = typeio.write;
const readerFn = typeio.read;
const Index = types.Index(type_prefix);
const fmt_str = "{s}.{x}." ++ @tagName(type_prefix);

pub fn new(repo: []const u8, trigger: []const u8, result: Result, src_hash: Hash, io: Io) !CI {
    const max: usize = try Index.scoped.next(repo, io);
    const now = Io.Clock.real.now(io).toSeconds();
    var ci = CI{
        .index = max,
        .created = now,
        .updated = now,
        .repo = repo,
        .hash = src_hash,
        .revision = 0,
        .trigger = trigger,
        .result = result,
    };

    var thread: Thread = try .new(CI, &ci, io);
    try thread.commit(io);
    ci.thread_id = thread.index;
    try ci.commit(io);
    return ci;
}

pub fn open(repo: []const u8, index: usize, a: Allocator, io: Io) !CI {
    const max = Index.scoped.current(repo, io) catch return error.FSFault;
    if (index > max) return error.CIDoesNotExist;

    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, fmt_str, .{ repo, index });
    var reader = types.loadDataReader(type_prefix, filename, a, io) catch return error.FSFault;
    return readerFn(&reader);
}

pub fn commit(ci: CI, io: Io) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, fmt_str, .{ ci.repo, ci.index });
    const file = try types.commit(type_prefix, filename, io);
    defer file.close(io);
    var w_b: [2048]u8 = undefined;
    var fd_writer = file.writer(io, &w_b);
    try writerFn(&ci, &fd_writer.interface);
}

pub fn loadThread(ci: *CI, a: Allocator, io: Io) !*Thread {
    if (ci.thread) |thr| return thr;
    const t = try a.create(Thread);
    t.* = Thread.open(ci.thread_id, a, io) catch |err| t: {
        log.err("Error loading thread!! {} old_id: {}", .{ err, ci.thread_id });
        const thread = Thread.new(CI, ci, io) catch |err2| {
            log.err(" unable to create new {}", .{err2});
            return error.UnableToLoadThread;
        };
        log.err("new thread_id {}", .{thread.index});
        ci.thread_id = thread.index;
        try ci.commit(io);
        break :t thread;
    };

    ci.thread = t;
    return t;
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
    try types.init(try tempdir.dir.createDirPathOpen(io, @tagName(type_prefix), .{ .open_options = .{ .iterate = true } }), io);

    var ci = try CI.new("srctree", "trigger", .err, @splat('z'), io);

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0x7ffffff);
    ci.created = Io.Clock.real.now(io).toSeconds() & mask;
    ci.updated = Io.Clock.real.now(io).toSeconds() & mask;

    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try writerFn(&ci, &writer.writer);

    const v1_text: []const u8 =
        \\# continuous_integration/0
        \\index: 1
        \\created: 1744830464
        \\updated: 1744830464
        \\repo: srctree
        \\hash: 7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a
        \\revision: 0
        \\trigger: trigger
        \\result: err
        \\thread_id: 1
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

const types = @import("../types.zig");
const Viewers = types.Viewers;
const Thread = types.Thread;
