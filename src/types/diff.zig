index: usize,
state: usize,
created: i64,
updated: i64,
applies: bool = false,
applies_hash: Types.Sha1Hex = @splat('0'),
delta_hash: Types.DefaultHash,
author: []const u8,
source_uri: ?[]const u8,
patch: struct {
    blob: []const u8,
},

const Diff = @This();

pub const type_prefix = "diffs";
pub const type_version: usize = 1;

const typeio = Types.readerWriter(Diff, .{
    .index = 0,
    .state = 0,
    .created = 0,
    .updated = 0,
    .author = &.{},
    .source_uri = &.{},
    .delta_hash = undefined,
    .patch = .{ .blob = undefined },
});

const writerFn = typeio.write;
const readerFn = typeio.read;

pub fn new(a: Allocator, delta: *Delta, author: []const u8, patch: []const u8) !Diff {
    const idx: usize = try Types.nextIndex(.diffs);
    const d = Diff{
        .index = idx,
        .state = 0,
        .created = std.time.timestamp(),
        .updated = std.time.timestamp(),
        .delta_hash = delta.hash,
        .source_uri = null,
        .author = author,
        .patch = .{ .blob = patch },
    };

    try d.commit();

    var old_attach: ?usize = null;
    switch (delta.attach) {
        .diff => {
            old_attach = delta.attach_target;
        },
        else => unreachable,
    }

    delta.attach = .diff;
    delta.attach_target = idx;

    // TODO use hash
    const msg = if (old_attach) |old|
        try allocPrint(a, "diff patch was updated from {} to {}", .{ old, idx })
    else
        try allocPrint(a, "diff patch was created {}", .{idx});

    try delta.addMessage(a, try .new(.diff_update, idx, author, msg));
    return d;
}

pub fn open(a: std.mem.Allocator, index: usize) !?Diff {
    const max = try Types.currentIndex(.diffs);
    if (index > max) return null;

    var buf: [512]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.diff", .{index});
    const data = try Types.loadData(.diffs, a, filename);
    var d: Diff = readerFn(data);

    if (indexOf(u8, data, "\n\n")) |start| {
        d.patch.blob = data[start..];
    } else d.patch.blob = &.{};

    return d;
}

pub fn commit(d: Diff) !void {
    var buf: [512]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.diff", .{d.index});
    const file = try Types.commit(.diffs, filename);
    defer file.close();
    var w_b: [2048]u8 = undefined;
    var fd_writer = file.writer(&w_b);
    try writerFn(&d, &fd_writer.interface);
    try fd_writer.interface.writeAll(d.patch.blob);
    try fd_writer.interface.flush();
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const allocPrint = std.fmt.allocPrint;
const indexOf = std.mem.indexOf;

const Types = @import("../types.zig");
const Delta = @import("delta.zig");
