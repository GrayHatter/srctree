repo: []const u8,
commit_sha: GitSha = .zeros,
created: types.Timestamp = 0,
updated: types.Timestamp = 0,
trigger: []const u8 = &.{},
result: Result = .unknown,
thread: Thread = .empty,

steps: ArrayList(Step) = .empty,

pub const CI = @This();
pub const Hash = types.DefaultHash;
pub const Step = @import("CI/Step.zig");

pub const blank: CI = .{
    .repo = &.{},
};

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

const TypeIo = types.TypedIo(CI);

pub fn typeIdent(ci: CI, w: *Io.Writer) !void {
    try w.print("{s}.{x}", .{ ci.repo, ci.commit_sha.hash.bytes() });
}

pub fn new(repo: []const u8, trigger: []const u8, sha: GitSha, io: Io) !CI {
    const now = Io.Clock.real.now(io).toSeconds();
    var ci = CI{
        .repo = repo,
        .commit_sha = sha,
        .created = now,
        .updated = now,
        .trigger = trigger,
        .result = .pending,
    };
    defer ci.commit(io) catch {};

    ci.thread = try .new(CI, &ci, io);
    return ci;
}

pub fn open(repo: []const u8, sha: GitSha, a: Allocator, io: Io) !CI {
    var ci: CI = .blank;
    ci.repo = repo;
    ci.commit_sha = sha;
    var reader = try TypeIo.loadData(&ci, a, io);
    defer reader.file.close(io);
    TypeIo.read(&ci, &reader.interface);

    try ci.steps.append(a, try .open(repo, sha, "build", a, io));
    try ci.steps.append(a, try .open(repo, sha, "tests", a, io));
    try ci.steps.append(a, try .open(repo, sha, "docs", a, io));
    return ci;
}

pub fn addStep(ci: *CI, step: Step, a: Allocator) !void {
    try ci.steps.append(a, step);
}

pub fn commit(ci: *const CI, io: Io) !void {
    var writer = try TypeIo.commitExtra(ci, io);
    defer writer.file.close(io);
    var w_b: [4096]u8 = undefined;
    writer.interface.buffer = &w_b;

    for (ci.steps.items) |step| {
        try writer.interface.print("{f}\n", .{step});
    }
    try writer.interface.flush();
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
    try types.init(
        try tempdir.dir.createDirPathOpen(io, @tagName(type_prefix), .{ .open_options = .{ .iterate = true } }),
        io,
    );

    var ci = try CI.new("srctree", "trigger", .{ .hash = .{ .sha1 = @splat('G') } }, io);
    types.testing.maskTime(&ci, io);
    ci.thread.src_hash = @splat('9');
    ci.thread.created = 0;
    ci.thread.updated = ci.updated;
    ci.result = .err;

    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try TypeIo.write(&ci, &writer.writer);

    const v1_text: []const u8 =
        \\# continuous_integration/0
        \\repo: srctree
        \\commit_sha: 4747474747474747474747474747474747474747
        \\created: 1744830464
        \\updated: 1744830464
        \\trigger: trigger
        \\result: err
        \\thread: idx=1 count=0 updated=1744830464 hash=3939393939393939393939393939393939393939393939393939393939393939
        \\
        \\
    ;

    try std.testing.expectEqualStrings(v1_text, writer.written());

    var r: Io.Reader = .fixed(writer.written());
    var read: CI = .blank;
    TypeIo.read(&read, &r);
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
const GitSha = types.GitSha;
const Viewers = types.Viewers;
const Thread = types.Thread;
