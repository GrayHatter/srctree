repo: []const u8,
commit_sha: GitSha = .zeros,
name: []const u8 = &.{},
result: CI.Result = .unknown,
created: types.Timestamp = 0,
updated: types.Timestamp = 0,
payload: []const u8 = &.{},

writer: ?Io.Writer = null,
active_fd: ?Io.File = null,

const Step = @This();

pub const blank: Step = .{
    .repo = &.{},
};

pub const type_prefix = .ci_step;
pub const type_version = 0;

const TypeIo = types.TypedIo(Step);

pub fn typeIdent(s: Step, w: *Io.Writer) !void {
    try w.print("{s}.{x}.{s}", .{ s.repo, s.commit_sha.hash.bytes(), s.name });
}

pub fn new(ci: *const CI, name: []const u8, payload: []const u8, io: Io) !Step {
    const now = Io.Clock.real.now(io).toSeconds();
    var step = Step{
        .repo = ci.repo,
        .commit_sha = ci.commit_sha,
        .name = name,
        .created = now,
        .updated = now,
        .result = .pending,
    };
    try step.commit(payload, io);
    return step;
}

pub fn open(repo: []const u8, sha: GitSha, name: []const u8, a: Allocator, io: Io) !Step {
    var step: Step = .blank;
    step.repo = repo;
    step.commit_sha = sha;
    step.name = name;
    var reader = try TypeIo.loadData(&step, a, io);
    defer reader.file.close(io);
    TypeIo.read(&step, &reader.interface);

    step.payload = reader.interface.buffered();
    return step;
}

pub fn commit(step: *const Step, payload: []const u8, io: Io) !void {
    var writer = try TypeIo.commitExtraSkip(step, io, &.{"payload"});
    defer writer.file.close(io);
    var w_b: [4096]u8 = undefined;
    writer.interface.buffer = &w_b;
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

pub fn format(step: Step, w: *Io.Writer) !void {
    try w.print("step: name={s} result={t}", .{ step.name, step.result });
}

test Step {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try types.init(try tempdir.dir.createDirPathOpen(io, @tagName(Step.type_prefix), .{ .open_options = .{ .iterate = true } }), io);

    const ci_proxy = types.TypedIo(CI);
    var ci = try CI.new("srctree", "testing_trigger", .{ .hash = .{ .sha256 = @splat('y') } }, io);

    types.testing.maskTime(&ci, io);
    ci.thread.created = ci.updated;
    ci.thread.updated = ci.updated;
    ci.thread.src_hash = @splat('9');
    ci.result = .err;
    try ci.addStep(try .new(&ci, "testing_step", "this is the payload", io), a);
    defer ci.steps.deinit(a);
    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try ci_proxy.write(&ci, &writer.writer);
    // Copied from commit()
    for (ci.steps.items) |step| {
        try writer.writer.print("{f}\n", .{step});
        step.commit("this is the payload", io) catch continue;
    }
    // end copy

    const ci_text: []const u8 =
        \\# continuous_integration/0
        \\repo: srctree
        \\commit_sha: 7979797979797979797979797979797979797979797979797979797979797979
        \\created: 1744830464
        \\updated: 1744830464
        \\trigger: testing_trigger
        \\result: err
        \\thread: idx=1 count=0 updated=1744830464 hash=3939393939393939393939393939393939393939393939393939393939393939
        \\
        \\step: name=testing_step result=pending
        \\
    ;

    try std.testing.expectEqualStrings(ci_text, writer.written());

    var step_writer = std.Io.Writer.Allocating.init(a);
    defer step_writer.deinit();
    types.testing.maskTime(&ci.steps.items[0], io);
    try TypeIo.write(&ci.steps.items[0], &step_writer.writer);
    var r: Io.Reader = .fixed(step_writer.written());
    var read: Step = undefined;
    TypeIo.read(&read, &r);
    const step_text =
        \\# ci_step/0
        \\repo: srctree
        \\commit_sha: 7979797979797979797979797979797979797979797979797979797979797979
        \\name: testing_step
        \\result: pending
        \\created: 1744830464
        \\updated: 1744830464
        \\
        \\
    ;
    try std.testing.expectEqualStrings(step_text, step_writer.written());
    //try std.testing.expectEqualDeep(ci.steps.items[0], read);
}

const std = @import("std");
const log = std.log.scoped(.srctree_type_ci);
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const bufPrint = std.fmt.bufPrint;
const parseInt = std.fmt.parseInt;

const types = @import("../../types.zig");
const CI = @import("../CI.zig");
const Viewers = types.Viewers;
const Thread = types.Thread;
const GitSha = types.GitSha;
