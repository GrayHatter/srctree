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
pub const Step = @import("CI/Step.zig");

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

pub const type_prefix = .continuous_integration;
pub const type_version = 0;

const typeio = types.readerWriter(CI, .{ .index = 0, .repo = &.{} });
const writerFn = typeio.write;
const readerFn = typeio.read;
const Index = types.Index(type_prefix);

pub fn new(repo: []const u8, trigger: []const u8, src_hash: Hash, io: Io) !CI {
    const max: usize = try Index.next(io);
    const now = Io.Clock.real.now(io).toSeconds();
    var ci = CI{
        .index = max,
        .created = now,
        .updated = now,
        .repo = repo,
        .hash = src_hash,
        .revision = 0,
        .trigger = trigger,
        .result = .pending,
    };

    var thread: Thread = try .new(CI, &ci, io);
    try thread.commit(io);
    ci.thread_id = thread.index;
    try ci.commit(io);
    return ci;
}

pub fn open(index: usize, a: Allocator, io: Io) !CI {
    const max = Index.current(io) catch return error.FSFault;
    if (index > max) return error.CIDoesNotExist;
    const reader = try Index.readerByIndex(index, a, io);
    var ci: CI = try readerFn(&reader);

    while (reader.takeDelimiterInclusive('\n') catch null) |line| {
        if (std.mem.cutPrefix(u8, line[0 .. line.len - 1], "step: ")) |prefix| {
            const step_index: usize = parseInt(usize, prefix, 0) catch 0;
            try ci.steps.append(a, try .open(step_index, a, io));
        }
    }
    return ci;
}

pub fn addStep(ci: *CI, step: Step, a: Allocator) !void {
    try ci.steps.append(a, step);
}

pub fn commit(ci: *const CI, io: Io) !void {
    const file = try Index.createFile(ci.index, io);
    defer file.close(io);
    var w_b: [4096]u8 = undefined;
    var writer = file.writer(io, &w_b);
    try writerFn(ci, &writer.interface);

    for (ci.steps.items) |step| {
        try writer.interface.print("{f}\n", .{step});
        step.commit(io) catch continue;
    }
    try writer.interface.flush();
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

    var ci = try CI.new("srctree", "trigger", @splat('z'), io);
    types.testing.maskTime(&ci, io);
    ci.result = .err;

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
const parseInt = std.fmt.parseInt;

const types = @import("../types.zig");
const Viewers = types.Viewers;
const Thread = types.Thread;
