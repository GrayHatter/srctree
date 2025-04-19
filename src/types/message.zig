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

pub const Message = @This();
const CMMT_VERSION: usize = 0;
pub const TYPE_PREFIX = "messages";
var datad: Types.Storage = undefined;
pub const HashType = [Sha256.digest_length]u8;
const ThreadIDType = Types.Thread.IDType;

state: usize = 0,
created: i64 = 0,
updated: i64 = 0,
src_tz: i32 = 0,
target: usize,
kind: Kind,
hash: HashType = undefined,
replies: ?usize = null,

pub const Flavor = enum(u16) {
    comment,
    _,
};

pub const Kind = union(Flavor) {
    comment: Comment,
};

pub const Comment = struct {
    author: []const u8,
    message: []const u8,

    pub fn readVersioned(a: Allocator, ver: usize, r: AnyReader) !Kind {
        return switch (ver) {
            0 => .{ .comment = .{
                .author = try r.readUntilDelimiterAlloc(a, 0, 0xFF),
                .message = try r.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            } },
            else => unreachable,
        };
    }

    pub fn writeOut(c: Comment, w: AnyWriter) !void {
        try w.writeAll(c.author);
        try w.writeInt(u8, 0, endian);
        try w.writeAll(c.message);
        try w.writeInt(u8, 0, endian);
    }

    pub fn updateHash(c: Comment, hash: *Sha256) void {
        hash.update(c.author);
        hash.update(c.message);
    }
};

pub fn init(_: []const u8) !void {}
pub fn initType(stor: Types.Storage) !void {
    datad = stor;
}

pub fn raze() void {
    datad.close();
}

fn readVersioned(a: Allocator, reader: AnyReader, hash: []const u8) !Message {
    const ver: usize = try reader.readInt(usize, endian);
    return switch (ver) {
        0 => return Message{
            .state = try reader.readInt(usize, endian),
            .created = try reader.readInt(i64, endian),
            .updated = try reader.readInt(i64, endian),
            .src_tz = try reader.readInt(i32, endian),
            .hash = hash[0..Sha256.digest_length].*,
            .target = try reader.readInt(ThreadIDType, endian),
            .kind = switch (reader.readEnum(Flavor, endian) catch return error.EnumError) {
                .comment => try Comment.readVersioned(a, ver, reader),
                else => return error.UnsupportedKind,
            },
            .replies = if ((reader.readInt(usize, endian) catch null)) |r| if (r == 0) null else r else null,
        },
        else => error.UnsupportedVersion,
    };
}

pub fn toHash(self: *Message) *const HashType {
    var h = Sha256.init(.{});
    h.update(std.mem.asBytes(&self.created));
    h.update(std.mem.asBytes(&self.updated));
    switch (self.kind) {
        .comment => |c| c.updateHash(&h),
        else => unreachable,
    }
    h.final(&self.hash);
    return &self.hash;
}

pub fn writeNew(self: *Message, d: std.fs.Dir) !void {
    var buf: [2048]u8 = undefined;
    _ = self.toHash();
    const filename = try bufPrint(&buf, "{x}.message", .{fmtSliceHexLower(&self.hash)});
    var file = try d.createFile(filename, .{});
    defer file.close();
    const w = file.writer().any();
    try self.writeOut(w);
}

pub fn commit(self: Message) !void {
    var file = try openFile(self.hash);
    defer file.close();
    const writer = file.writer().any();
    try self.writeOut(writer);
}

fn writeOut(self: Message, w: AnyWriter) !void {
    try w.writeInt(usize, CMMT_VERSION, endian);
    try w.writeInt(usize, self.state, endian);
    try w.writeInt(i64, self.created, endian);
    try w.writeInt(i64, self.updated, endian);
    try w.writeInt(i32, self.src_tz, endian);
    try w.writeInt(ThreadIDType, self.target, endian);
    try w.writeInt(u16, @intFromEnum(self.kind), endian);
    switch (self.kind) {
        .comment => |c| try c.writeOut(w),
        else => unreachable,
    }
    try w.writeInt(usize, if (self.replies) |r| r else 0, endian);
}

pub fn readFile(a: std.mem.Allocator, file: std.fs.File, hash: []const u8) !Message {
    const reader = file.reader().any();
    return readVersioned(a, reader, hash);
}

fn openFile(hash: HashType) !std.fs.File {
    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, "{}.message", .{fmtSliceHexLower(hash[0..])});
    return try datad.openFile(filename, .{ .mode = .read_write });
}

pub fn open(a: Allocator, hash: HashType) !Message {
    var file = try openFile(hash);
    defer file.close();
    return try Message.readFile(a, file, hash[0..]);
}

pub fn newComment(tid: ThreadIDType, c: Comment) !Message {
    var m = Message{
        .target = tid,
        .kind = .{ .comment = c },
        .created = std.time.timestamp(),
        .updated = std.time.timestamp(),
    };
    try m.writeNew(datad);

    return m;
}

test "comment" {
    var a = std.testing.allocator;

    var c = Message{
        .target = 0,
        .kind = .{ .comment = .{
            .author = "grayhatter",
            .message = "test comment, please ignore",
        } },
    };

    const hash = c.toHash();
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0xA3, 0xE1, 0x6B, 0xD7, 0x46, 0xDC, 0x52, 0x43, 0x7B, 0xBC, 0x38, 0x99, 0x97, 0x0E, 0xD8, 0xEC,
            0x77, 0xFD, 0x99, 0x16, 0x87, 0xA4, 0x19, 0x50, 0x12, 0x6A, 0x1D, 0xCD, 0xCA, 0x61, 0xC6, 0xB3,
        },
        hash,
    );

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try c.writeNew(dir.dir);

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.message", .{std.fmt.fmtSliceHexLower(hash)});
    try std.testing.expectEqualStrings(
        "a3e16bd746dc52437bbc3899970ed8ec77fd991687a41950126a1dcdca61c6b3.message",
        filename,
    );
    const blob = try dir.dir.readFileAlloc(a, filename, 0xFF);
    defer a.free(blob);

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x67, 0x72,
            0x61, 0x79, 0x68, 0x61, 0x74, 0x74, 0x65, 0x72, 0x00, 0x74, 0x65, 0x73, 0x74, 0x20, 0x63, 0x6F,
            0x6D, 0x6D, 0x65, 0x6E, 0x74, 0x2C, 0x20, 0x70, 0x6C, 0x65, 0x61, 0x73, 0x65, 0x20, 0x69, 0x67,
            0x6E, 0x6F, 0x72, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        },
        blob,
    );
}

test Message {
    const a = std.testing.allocator;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init(try tempdir.dir.makeOpenPath("datadir", .{ .iterate = true }));

    var c = try Message.newComment(0, .{ .author = "author", .message = "message" });

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0xffffff);
    c.created = std.time.timestamp() & mask;
    c.updated = std.time.timestamp() & mask;

    var out = std.ArrayList(u8).init(a);
    defer out.clearAndFree();
    const outw = out.writer().any();
    try c.writeOut(outw);

    const v0: Message = undefined;
    const v0_bin: []const u8 = &[_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x68, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x68, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x61, 0x75,
        0x74, 0x68, 0x6F, 0x72, 0x00, 0x6D, 0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectEqualSlices(u8, v0_bin, out.items);
    const v1: Message = undefined;
    // TODO... eventually
    _ = v0;
    _ = v1;

    const v1_bin: []const u8 = &[_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x68, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x68, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x61, 0x75,
        0x74, 0x68, 0x6F, 0x72, 0x00, 0x6D, 0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectEqualSlices(u8, v1_bin, out.items);
}
