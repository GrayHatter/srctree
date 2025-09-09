state: usize = 0,
created: i64 = 0,
updated: i64 = 0,
src_tz: i32 = 0,
target: usize,
author: ?[]const u8 = null,
message: ?[]const u8 = null,
kind: Kind,
hash: DefaultHash,

const Message = @This();

pub const Kind = enum(u16) {
    comment,
};

pub const type_prefix = "messages";
pub const type_version = 0;

const typeio = Types.readerWriter(Message, .{ .target = undefined, .kind = undefined, .hash = @splat(0) });
const writerFn = typeio.write;
const readerFn = typeio.read;

pub fn new(tid: usize, author: []const u8, message: []const u8) !Message {
    var m = Message{
        .target = tid,
        .kind = .comment,
        .created = std.time.timestamp(),
        .updated = std.time.timestamp(),
        .author = author,
        .message = message,
        .hash = @splat(0),
    };
    _ = m.genHash();
    try m.commit();
    return m;
}

pub fn commit(msg: Message) !void {
    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, "{x}.message", .{&msg.hash});
    const file = try Types.commit(.message, filename);
    defer file.close();

    std.debug.assert(!std.mem.eql(u8, msg.hash[0..], &[_]u8{0} ** 32));
    var w_b: [2048]u8 = undefined;
    var fd_writer = file.writer(&w_b);
    try writerFn(&msg, &fd_writer.interface);
}

pub fn open(a: Allocator, hash: DefaultHash) !Message {
    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, "{x}.message", .{&hash});
    const file = try Types.loadData(.message, a, filename);
    return readerFn(file);
}

pub fn genHash(msg: *Message) *const DefaultHash {
    std.debug.assert(std.mem.eql(u8, msg.hash[0..], &[_]u8{0} ** 32));
    var h = Sha256.init(.{});
    h.update(asBytes(&msg.target));
    h.update(asBytes(&msg.created));
    h.update(asBytes(&msg.updated));
    switch (msg.kind) {
        .comment => {
            h.update(msg.author orelse "");
            h.update(msg.message orelse "");
        },
    }
    h.final(&msg.hash);
    return &msg.hash;
}

test "comment" {
    const a = std.testing.allocator;
    var c = Message{
        .target = 0,
        .kind = .comment,
        .author = "grayhatter",
        .message = "test comment, please ignore",
        .hash = @splat(0),
    };

    const hash = c.genHash();
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x4A, 0x3C, 0x01, 0x61, 0x69, 0x59, 0xEE, 0x54, 0x92, 0x66, 0x78, 0xE1, 0x74, 0xFC, 0x7E, 0x42,
            0x16, 0x48, 0x0A, 0xB2, 0xA7, 0x1C, 0xB7, 0x45, 0x13, 0xD5, 0xD1, 0x36, 0xDE, 0x35, 0xBA, 0xCE,
        },
        hash,
    );

    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init(try tempdir.dir.makeOpenPath("datadir", .{ .iterate = true }));

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.message", .{hash});
    try std.testing.expectEqualStrings(
        "4a3c01616959ee54926678e174fc7e4216480ab2a71cb74513d5d136de35bace.message",
        filename,
    );

    {
        var file = try Types.commit(.message, filename);
        defer file.close();
        var w_b: [2048]u8 = undefined;
        var writer = file.writer(&w_b);
        try writerFn(&c, &writer.interface);
    }
    const data = try Types.loadData(.message, a, filename);
    defer a.free(data);

    const expected =
        \\# messages/0
        \\state: 0
        \\created: 0
        \\updated: 0
        \\src_tz: 0
        \\target: 0
        \\author: grayhatter
        \\message: test comment, please ignore
        \\kind: comment
        \\hash: 4a3c01616959ee54926678e174fc7e4216480ab2a71cb74513d5d136de35bace
        \\
        \\
    ;

    try std.testing.expectEqualStrings(expected, data);
}

test Message {
    const a = std.testing.allocator;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init(try tempdir.dir.makeOpenPath("datadir", .{ .iterate = true }));

    var c = try Message.new(0, "author", "message");

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0xffffff);
    c.created = std.time.timestamp() & mask;
    c.updated = std.time.timestamp() & mask;
    // required to overwrite the timestamp
    c.hash = @splat(0);
    _ = c.genHash();
    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try writerFn(&c, &writer.writer);

    const v0_text =
        \\# messages/0
        \\state: 0
        \\created: 1744830464
        \\updated: 1744830464
        \\src_tz: 0
        \\target: 0
        \\author: author
        \\message: message
        \\kind: comment
        \\hash: cd72e644d5a5c4c99fd9a813959b428a2eaafbbfbed03737c9b075d3fc12f8c4
        \\
        \\
    ;

    try std.testing.expectEqualStrings(v0_text, writer.written());
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();
const Sha256 = std.crypto.hash.sha2.Sha256;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const asBytes = std.mem.asBytes;
const DefaultHash = Types.DefaultHash;

const Humanize = @import("../humanize.zig");
const Types = @import("../types.zig");
