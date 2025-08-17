state: usize = 0,
created: i64 = 0,
updated: i64 = 0,
src_tz: i32 = 0,
target: usize,
author: ?[]const u8 = null,
message: ?[]const u8 = null,
kind: Kind,
hash: HashType = undefined,

const Message = @This();

pub const type_prefix = "messages";
pub const type_version = 0;
pub const HashType = [Sha256.digest_length]u8;

const typeio = Types.readerWriter(Message, .{ .target = undefined, .kind = undefined });
const writerFn = typeio.write;
const readerFn = typeio.read;

pub const Kind = enum(u16) {
    comment,
};

pub fn commit(msg: Message) !void {
    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, "{x}.message", .{fmtSliceHexLower(&msg.hash)});
    const file = try Types.commit(.message, filename);
    defer file.close();

    var writer = file.writer();
    try writerFn(&msg, &writer);
}

pub fn open(a: Allocator, hash: HashType) !Message {
    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, "{x}.message", .{fmtSliceHexLower(&hash)});
    const file = try Types.loadData(.message, a, filename);
    return readerFn(file);
}

pub fn genHash(msg: *Message) *const HashType {
    var h = Sha256.init(.{});
    h.update(std.mem.asBytes(&msg.created));
    h.update(std.mem.asBytes(&msg.updated));
    switch (msg.kind) {
        .comment => {
            h.update(msg.author orelse "");
            h.update(msg.message orelse "");
        },
        //else => comptime unreachable,
    }
    h.final(&msg.hash);
    return &msg.hash;
}

pub fn newComment(tid: usize, author: []const u8, message: []const u8) !Message {
    var m = Message{
        .target = tid,
        .kind = .comment,
        .created = std.time.timestamp(),
        .updated = std.time.timestamp(),
        .author = author,
        .message = message,
    };
    _ = m.genHash();
    try m.commit();
    return m;
}

test "comment" {
    const a = std.testing.allocator;
    var c = Message{
        .target = 0,
        .kind = .comment,
        .author = "grayhatter",
        .message = "test comment, please ignore",
    };

    const hash = c.genHash();
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0xA3, 0xE1, 0x6B, 0xD7, 0x46, 0xDC, 0x52, 0x43, 0x7B, 0xBC, 0x38, 0x99, 0x97, 0x0E, 0xD8, 0xEC,
            0x77, 0xFD, 0x99, 0x16, 0x87, 0xA4, 0x19, 0x50, 0x12, 0x6A, 0x1D, 0xCD, 0xCA, 0x61, 0xC6, 0xB3,
        },
        hash,
    );

    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init(try tempdir.dir.makeOpenPath("datadir", .{ .iterate = true }));

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.message", .{std.fmt.fmtSliceHexLower(hash)});
    try std.testing.expectEqualStrings(
        "a3e16bd746dc52437bbc3899970ed8ec77fd991687a41950126a1dcdca61c6b3.message",
        filename,
    );

    {
        var file = try Types.commit(.message, filename);
        defer file.close();
        var writer = file.writer();
        try writerFn(&c, &writer);
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
        \\hash: a3e16bd746dc52437bbc3899970ed8ec77fd991687a41950126a1dcdca61c6b3
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

    var c = try Message.newComment(0, "author", "message");

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0xffffff);
    c.created = std.time.timestamp() & mask;
    c.updated = std.time.timestamp() & mask;
    _ = c.genHash();
    var out = std.ArrayList(u8).init(a);
    defer out.clearAndFree();
    var writer = out.writer();
    try writerFn(&c, &writer);

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
        \\hash: eb67086c9a948168cd49f13a46c81603c21851c46dd068fc534c85bfbc0b0cbc
        \\
        \\
    ;

    try std.testing.expectEqualStrings(v0_text, out.items);
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();
const Sha256 = std.crypto.hash.sha2.Sha256;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const AnyWriter = std.io.AnyWriter;
const AnyReader = std.io.AnyReader;
const fmtSliceHexLower = std.fmt.fmtSliceHexLower;

const Humanize = @import("../humanize.zig");
const Types = @import("../types.zig");
