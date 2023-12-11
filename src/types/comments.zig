const std = @import("std");

const Allocator = std.mem.Allocator;
const sha256 = std.crypto.hash.sha2.Sha256;

pub const Comments = @This();

pub const SupportedTargets = union(enum) {
    nos: void,
    diff: usize,
};

pub const Comment = struct {
    author: []const u8,
    message: []const u8,
    created: i64 = 0,
    tz: i32 = 0,
    updated: i64 = 0,

    target: SupportedTargets = .{ .nos = {} },

    alloc_data: ?[]u8 = null,
    hash: [sha256.digest_length]u8 = undefined,

    pub fn toHash(self: *Comment) *const [sha256.digest_length]u8 {
        var h = sha256.init(.{});
        h.update(self.author);
        h.update(self.message);
        h.update(std.mem.asBytes(&self.created));
        h.update(std.mem.asBytes(&self.updated));
        h.final(&self.hash);
        return &self.hash;
    }

    pub fn writeNew(self: *Comment, d: std.fs.Dir) !void {
        var buf: [2048]u8 = undefined;
        _ = self.toHash();
        const filename = try std.fmt.bufPrint(&buf, "{x}.comment", .{std.fmt.fmtSliceHexLower(&self.hash)});
        var file = try d.createFile(filename, .{});
        defer file.close();
        var w = file.writer();
        try w.writeAll(self.author);
        try w.writeAll("\x00");
        try w.writeAll(self.message);
        try w.writeAll("\x00");
        try w.writeIntNative(i64, self.created);
        try w.writeIntNative(i64, self.updated);
        try w.writeAll("\x00");
        try w.writeAll(std.mem.asBytes(&self.target));
    }

    pub fn readFile(a: std.mem.Allocator, file: std.fs.File) !Comment {
        const end = try file.getEndPos();
        var data = try a.alloc(u8, end);
        errdefer a.free(data);
        try file.seekTo(0);
        _ = try file.readAll(data);
        var itr = std.mem.split(u8, data, "\x00");
        var c = Comment{
            .author = itr.first(),
            .message = itr.next().?,
            .alloc_data = data,
        };
        return c;
    }
};

var datad: std.fs.Dir = undefined;

pub fn init(dir: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}/messages", .{dir});
    datad = try std.fs.cwd().openDir(filename, .{});
}

pub fn raze() void {
    datad.close();
}

pub fn open(a: Allocator, hash: []const u8) !Comment {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.comment", .{std.fmt.fmtSliceHexLower(hash)});
    var file = try datad.openFile(filename, .{});
    defer file.close();
    return try Comment.readFile(a, file);
}

pub fn new(ath: []const u8, msg: []const u8) !Comment {
    var c = Comment{
        .author = ath,
        .message = msg,
    };
    try c.writeNew(datad);

    return c;
}

pub fn loadFromData(a: Allocator, cd: []const u8) ![]Comment {
    if (cd.len < 32) {
        std.debug.print("unexpected number in comment data {}\n", .{cd.len});
        return &[0]Comment{};
    }
    const count = cd.len / 32;
    if (count == 0) return &[0]Comment{};
    var comments = try a.alloc(Comment, count);
    for (comments, 0..) |*c, i| {
        c.* = try Comments.open(a, cd[i * 32 .. (i + 1) * 32]);
    }
    return comments;
}

test "comment" {
    var a = std.testing.allocator;

    var c = Comment{
        .author = "grayhatter",
        .message = "test comment, please ignore",
    };

    // zig fmt: off
    var hash = c.toHash();
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0x21, 0x78, 0x05, 0xE5, 0xB5, 0x0C, 0x05, 0xF5, 0x22, 0xAC, 0xFE, 0xBA, 0xEA, 0xA4, 0xAC, 0xC2,
            0xD6, 0x50, 0xD1, 0xDD, 0x48, 0xFC, 0x34, 0x0E, 0xBB, 0x53, 0x94, 0x60, 0x56, 0x93, 0xC9, 0xC8
        },
        hash,
    );
    // zig fmt: on

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try c.writeNew(dir.dir);

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.comment", .{std.fmt.fmtSliceHexLower(hash)});
    try std.testing.expectEqualStrings(
        "217805e5b50c05f522acfebaeaa4acc2d650d1dd48fc340ebb5394605693c9c8.comment",
        filename,
    );
    var blob = try dir.dir.readFileAlloc(a, filename, 0xFF);
    defer a.free(blob);

    // zig fmt: off
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            103, 114,  97, 121, 104,  97, 116, 116, 101, 114,
              0, 116, 101, 115, 116,  32,  99, 111, 109, 109,
            101, 110, 116,  44,  32, 112, 108, 101,  97, 115,
            101,  32, 105, 103, 110, 111, 114, 101,   0,   0,
              0,   0,   0,   0,   0,   0,   0,   0,
              0,   0,   0,   0,   0,   0,   0,   0,
              0,   0,   0,   0,   0,   0,   0,   0,
              0,   0,   0,   0,   0,   0,   0,   0,
        },
        blob,
    );
    // zig fmt: on
}
