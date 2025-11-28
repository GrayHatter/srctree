index: usize,
state: State = .nos,
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

// TODO reimplement as packed struct once supported by Types.readerWriter
pub const State = enum(usize) {
    nos = 0,
    // Bool bits
    pending = 1,
    curl = 2,
    pending_curl = 3,
};

const typeio = Types.readerWriter(Diff, .{
    .index = 0,
    .created = 0,
    .updated = 0,
    .author = &.{},
    .source_uri = &.{},
    .delta_hash = undefined,
    .patch = .{ .blob = undefined },
});

const writerFn = typeio.write;
const readerFn = typeio.read;

pub fn new(delta: *Delta, author: []const u8, patch: []const u8, a: Allocator, io: Io) !Diff {
    const idx: usize = try Types.nextIndex(.diffs, io);
    const d = Diff{
        .index = idx,
        .state = .nos,
        .created = (try Io.Clock.now(.real, io)).toSeconds(),
        .updated = (try Io.Clock.now(.real, io)).toSeconds(),
        .delta_hash = delta.hash,
        .source_uri = null,
        .author = author,
        .patch = .{ .blob = patch },
    };

    try d.commit(io);

    var old_attach: ?usize = null;
    switch (delta.attach) {
        .nos => old_attach = null,
        .diff => old_attach = delta.attach_target,
        .issue, .commit, .line => unreachable, // not implemented
    }

    delta.attach = .diff;
    delta.attach_target = idx;

    // TODO use hash
    const msg = if (old_attach) |old|
        try allocPrint(a, "diff patch was updated from {} to {}", .{ old, idx })
    else
        try allocPrint(a, "diff patch was created {}", .{idx});

    try delta.addMessage(try .new(.diff_update, idx, author, msg, io), a, io);
    return d;
}

pub fn open(index: usize, a: Allocator, io: Io) !?Diff {
    const max = try Types.currentIndex(.diffs, io);
    if (index > max) return null;

    var buf: [512]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.diff", .{index});
    var reader = try Types.loadDataReader(.diffs, filename, a, io);
    var d: Diff = readerFn(&reader);

    // TODO reader.buffered();
    if (indexOf(u8, reader.buffer, "\n\n")) |start| {
        d.patch.blob = reader.buffer[start..];
    } else d.patch.blob = &.{};

    return d;
}

pub fn commit(d: Diff, io: Io) !void {
    var buf: [512]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.diff", .{d.index});
    const file = try Types.commit(.diffs, filename, io);
    defer file.close();
    var w_b: [2048]u8 = undefined;
    var fd_writer = file.writer(&w_b);
    try writerFn(&d, &fd_writer.interface);
    try fd_writer.interface.writeAll(d.patch.blob);
    try fd_writer.interface.flush();
}

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const allocPrint = std.fmt.allocPrint;
const indexOf = std.mem.indexOf;

const Types = @import("../types.zig");
const Delta = @import("delta.zig");
