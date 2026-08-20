hash: DefaultHash,
state: State = .default,
target: usize,
kind: Kind,
created: i64 = 0,
updated: i64 = 0,
src_tz: i32 = 0,
author: ?[]const u8 = null,
//sub_thread: usize = 0,
// TODO stabilize or replace this hack
extra0: usize = 0,
// Processed internally
message: []const u8,

const Message = @This();

pub const empty: Message = .{
    .hash = @splat(0),
    .state = .default,
    .target = undefined,
    .kind = undefined,
    .message = &.{},
};

pub const State = @import("common.zig").State;

pub const Kind = enum(u16) {
    comment,
    diff_update,
    state_change,
};

pub const type_prefix = .messages;
pub const type_version = 0;
pub const type_skip_fields: [1][]const u8 = .{"message"};

const typeio = Types.readerWriter(Message, .empty);
const writerFn = typeio.write;
const readerFn = typeio.read;

pub fn new(kind: Kind, tid: usize, author: []const u8, message: []const u8, io: Io) !Message {
    var m = Message{
        .hash = @splat(0),
        .state = .default,
        .kind = kind,
        .target = tid,
        .created = Io.Clock.real.now(io).toSeconds(),
        .updated = Io.Clock.real.now(io).toSeconds(),
        .author = author,
        .message = message,
    };
    _ = m.genHash();
    try m.commit(io);
    return m;
}

pub fn commit(msg: Message, io: Io) !void {
    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, "{x}.message", .{&msg.hash});
    const file = try Types.commit(.message, filename, io);
    defer file.close(io);

    std.debug.assert(!std.mem.eql(u8, msg.hash[0..], &[_]u8{0} ** 32));
    var w_b: [2048]u8 = undefined;
    var fd_writer = file.writer(io, &w_b);
    try writerFn(&msg, &fd_writer.interface);
    try fd_writer.interface.writeAll(msg.message);
    try fd_writer.interface.flush();
}

pub fn open(hash: DefaultHash, a: Allocator, io: Io) !Message {
    var reader = try Types.loadDataHashId(.message, hash, a, io);
    var msg = readerFn(&reader);

    if (msg.message.len == 0) {
        if (find(u8, reader.buffer, "\n\n")) |start| {
            msg.message = reader.buffer[start + 2 ..];
        }
    }
    return msg;
}

pub fn genHash(msg: *Message) *const DefaultHash {
    std.debug.assert(std.mem.eql(u8, msg.hash[0..], &[_]u8{0} ** 32));
    var h = Sha256.init(.{});
    h.update(asBytes(&msg.state));
    h.update(asBytes(&msg.target));
    h.update(asBytes(&msg.created));
    h.update(asBytes(&msg.updated));
    h.update(asBytes(&@intFromEnum(msg.kind)));
    switch (msg.kind) {
        .comment => {
            h.update(msg.author orelse "");
            h.update(msg.message);
        },
        .diff_update => {
            h.update(msg.author orelse "");
            // Message is required for diff patch updates
            h.update(msg.message);
        },
        .state_change => {
            h.update(msg.author orelse "");
            h.update(msg.message);
        },
    }
    h.final(&msg.hash);
    return &msg.hash;
}

test "comment" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var c = Message{
        .target = 0,
        .state = .default,
        .kind = .comment,
        .author = "grayhatter",
        .message = "test comment, please ignore",
        .hash = @splat(0),
    };

    const hash = c.genHash();
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xA0, 0x2D, 0xAB, 0x93, 0x4D, 0x06, 0xAB, 0xDF, 0x94, 0xCB, 0x24, 0xC9, 0x8D, 0x07, 0xB1, 0xA0,
        0xC0, 0x2B, 0x12, 0xBE, 0xF3, 0x92, 0x23, 0x49, 0xC5, 0x34, 0x26, 0x9D, 0x0E, 0x34, 0x0A, 0x6E,
    }, hash);

    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init(try tempdir.dir.createDirPathOpen(io, "datadir", .{ .open_options = .{ .iterate = true } }), io);

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.message", .{hash});
    try std.testing.expectEqualStrings(
        "a02dab934d06abdf94cb24c98d07b1a0c02b12bef3922349c534269d0e340a6e.message",
        filename,
    );

    {
        var file = try Types.commit(.message, filename, io);
        defer file.close(io);
        var w_b: [2048]u8 = undefined;
        var writer = file.writer(io, &w_b);
        try writerFn(&c, &writer.interface);
    }

    const reader = try Types.loadDataReader(.message, filename, a, io);
    defer a.free(reader.buffer);

    const expected =
        \\# messages/0
        \\hash: a02dab934d06abdf94cb24c98d07b1a0c02b12bef3922349c534269d0e340a6e
        \\state.closed: false
        \\state.draft: false
        \\state.embargoed: false
        \\state.locked: false
        \\state.removed: false
        \\target: 0
        \\kind: comment
        \\created: 0
        \\updated: 0
        \\src_tz: 0
        \\author: grayhatter
        \\extra0: 0
        \\
        \\
    ;

    try std.testing.expectEqualStrings(expected, reader.buffer);
}

test Message {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init((try tempdir.dir.createDirPathOpen(io, "datadir", .{ .open_options = .{ .iterate = true } })), io);

    var c = try Message.new(.comment, 0, "author", "message", io);

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0x7ffffff);
    c.created = Io.Clock.real.now(io).toSeconds() & mask;
    c.updated = Io.Clock.real.now(io).toSeconds() & mask;
    // required to overwrite the timestamp
    c.hash = @splat(0);
    _ = c.genHash();
    try c.commit(io);
    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try writerFn(&c, &writer.writer);

    var b: [4086]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&b);
    const aa = fba.allocator();
    const new_ut = try Message.open(c.hash, aa, io);
    try std.testing.expectEqualDeep(c, new_ut);

    const v0_text =
        \\# messages/0
        \\hash: 0cd7f83061495c5f82703d436a18d8d7545fd64d1c8d5c109539c216f72b7859
        \\state.closed: false
        \\state.draft: false
        \\state.embargoed: false
        \\state.locked: false
        \\state.removed: false
        \\target: 0
        \\kind: comment
        \\created: 1744830464
        \\updated: 1744830464
        \\src_tz: 0
        \\author: author
        \\extra0: 0
        \\
        \\message
    ;

    try std.testing.expectEqualStrings(v0_text, b[0..v0_text.len]);
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const endian = builtin.cpu.arch.endian();
const Sha256 = std.crypto.hash.sha2.Sha256;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const asBytes = std.mem.asBytes;
const find = std.mem.find;
const DefaultHash = Types.DefaultHash;

const Humanize = @import("../humanize.zig");
const Types = @import("../types.zig");
