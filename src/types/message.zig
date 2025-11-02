hash: DefaultHash,
state: usize,
target: usize,
kind: Kind,
created: i64 = 0,
updated: i64 = 0,
src_tz: i32 = 0,
author: ?[]const u8 = null,
message: ?[]const u8 = null,
// TODO stabilize or replace this hack
extra0: usize = 0,

const Message = @This();

pub const Kind = enum(u16) {
    comment,
    diff_update,
};

pub const type_prefix = "messages";
pub const type_version = 0;

const typeio = Types.readerWriter(Message, .{
    .hash = @splat(0),
    .state = 0,
    .target = undefined,
    .kind = undefined,
});
const writerFn = typeio.write;
const readerFn = typeio.read;

pub fn new(kind: Kind, tid: usize, author: []const u8, message: []const u8) !Message {
    var m = Message{
        .hash = @splat(0),
        .state = 0,
        .kind = kind,
        .target = tid,
        .created = std.time.timestamp(),
        .updated = std.time.timestamp(),
        .author = author,
        .message = message,
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
    h.update(asBytes(&@intFromEnum(msg.kind)));
    switch (msg.kind) {
        .comment => {
            h.update(msg.author orelse "");
            h.update(msg.message orelse "");
        },
        .diff_update => {
            h.update(msg.author orelse "");
            // Message is required for diff patch updates
            h.update(msg.message.?);
        },
    }
    h.final(&msg.hash);
    return &msg.hash;
}

test "comment" {
    const a = std.testing.allocator;
    var c = Message{
        .target = 0,
        .state = 0,
        .kind = .comment,
        .author = "grayhatter",
        .message = "test comment, please ignore",
        .hash = @splat(0),
    };

    const hash = c.genHash();
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x5A, 0x6E, 0x83, 0xD6, 0xDE, 0xC1, 0x97, 0x77, 0x8A, 0x73, 0x79, 0xBB, 0x32, 0x76, 0xDF, 0xF2,
            0xB3, 0x74, 0xBB, 0x02, 0x19, 0x45, 0xB0, 0x29, 0x44, 0xEF, 0x00, 0xDC, 0x91, 0x62, 0x29, 0x41,
        },
        hash,
    );

    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init(try tempdir.dir.makeOpenPath("datadir", .{ .iterate = true }));

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.message", .{hash});
    try std.testing.expectEqualStrings(
        "5a6e83d6dec197778a7379bb3276dff2b374bb021945b02944ef00dc91622941.message",
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
        \\hash: 5a6e83d6dec197778a7379bb3276dff2b374bb021945b02944ef00dc91622941
        \\state: 0
        \\target: 0
        \\kind: comment
        \\created: 0
        \\updated: 0
        \\src_tz: 0
        \\author: grayhatter
        \\message: test comment, please ignore
        \\extra0: 0
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

    var c = try Message.new(.comment, 0, "author", "message");

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0x7ffffff);
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
        \\hash: ec491fbb9d29b35270925653168a308e1d978fda0397d3993eb15990a1fcb80e
        \\state: 0
        \\target: 0
        \\kind: comment
        \\created: 1744830464
        \\updated: 1744830464
        \\src_tz: 0
        \\author: author
        \\message: message
        \\extra0: 0
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
