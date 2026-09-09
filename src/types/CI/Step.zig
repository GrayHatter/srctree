index: usize,
ci_index: usize,
result: CI.Result = .unknown,
created: types.Timestamp = 0,
updated: types.Timestamp = 0,
name: []const u8 = &.{},
payload: []const u8 = &.{},

writer: ?Io.Writer = null,
active_fd: ?Io.File = null,

const Step = @This();

pub const type_prefix = .ci_step;
pub const type_version = 0;
const type_rw = types.readerWriter(Step, .{ .index = 0, .ci_index = 0 });
const writerFn = type_rw.write;
const readerFn = type_rw.read;
const Index = types.Index(Step.type_prefix);

pub fn new(ci: *const CI, name: []const u8, io: Io) !Step {
    const max: usize = try Step.Index.next(io);
    const now = Io.Clock.real.now(io).toSeconds();
    var step = Step{
        .index = max,
        .ci_index = ci.index,
        .created = now,
        .updated = now,
        .result = .pending,
        .name = name,
    };
    try step.commit(io);
    return step;
}

pub fn open(index: usize, a: Allocator, io: Io) !Step {
    const max = Step.Index.current(io) catch return error.FSFault;
    if (index > max) return error.CIDoesNotExist;

    var file = Step.Index.openByIndex(index, io) catch return error.FSFault;
    defer file.close(io);

    const stat = try file.stat(io);
    const buf = try a.alloc(u8, stat.size);
    errdefer a.free(buf);
    var reader = file.reader(io, buf);
    try reader.interface.fill(stat.size);

    const step = Step.readerFn(&reader);
    step.payload = reader.interface.buffered();
    return step;
}

pub fn commit(step: *const Step, io: Io) !void {
    const file = try Step.Index.createByIndex(step.index, io);
    defer file.close(io);
    var w_b: [4096]u8 = undefined;
    var fd_writer = file.writer(io, &w_b);
    var copy = step.*;
    copy.payload = &.{};
    try Step.writerFn(&copy, &fd_writer.interface);
    try fd_writer.interface.writeAll(step.payload);
    try fd_writer.interface.flush();
}

pub fn format(step: Step, w: *Io.Writer) !void {
    try w.print("step: {}", .{step.index});
}

test Step {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try types.init(try tempdir.dir.createDirPathOpen(io, @tagName(Step.type_prefix), .{ .open_options = .{ .iterate = true } }), io);

    const ci_proxy = types.readerWriter(CI, .{ .index = 0, .repo = &.{} });
    var ci = try CI.new("srctree", "trigger", @splat('y'), io);
    const ciwriterFn = ci_proxy.write;

    types.testing.maskTime(&ci, io);
    ci.result = .err;
    try ci.addStep(try .new(&ci, "testing_step", io), a);
    defer ci.steps.deinit(a);
    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try ciwriterFn(&ci, &writer.writer);
    // Copied from commit()
    for (ci.steps.items) |step| {
        try writer.writer.print("{f}\n", .{step});
        step.commit(io) catch continue;
    }
    // end copy

    const ci_text: []const u8 =
        \\# continuous_integration/0
        \\index: 1
        \\created: 1744830464
        \\updated: 1744830464
        \\repo: srctree
        \\hash: 7979797979797979797979797979797979797979797979797979797979797979
        \\revision: 0
        \\trigger: trigger
        \\result: err
        \\thread_id: 1
        \\
        \\step: 1
        \\
    ;

    try std.testing.expectEqualStrings(ci_text, writer.written());

    var step_writer = std.Io.Writer.Allocating.init(a);
    defer step_writer.deinit();
    types.testing.maskTime(&ci.steps.items[0], io);
    try Step.writerFn(&ci.steps.items[0], &step_writer.writer);
    var r: Io.Reader = .fixed(step_writer.written());
    const read = Step.readerFn(&r);
    const step_text =
        \\# ci_step/0
        \\index: 1
        \\ci_index: 1
        \\result: pending
        \\created: 1744830464
        \\updated: 1744830464
        \\name: testing_step
        \\
        \\
    ;
    try std.testing.expectEqualStrings(step_text, step_writer.written());
    try std.testing.expectEqualDeep(ci.steps.items[0], read);
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
