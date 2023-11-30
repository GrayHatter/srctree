const std = @import("std");

const Allocator = std.mem.Allocator;
const sha256 = std.crypto.hash.sha2.Sha256;

pub const Comments = @This();

pub const Comment = struct {
    author: []const u8,
    message: []const u8,
    time: i64 = 0,
    tz: i32 = 0,

    target: union(enum) {
        nos: void,
        diff: usize,
    } = .{ .nos = {} },

    alloc_data: ?[]u8 = null,
    hash: [sha256.digest_length]u8 = undefined,

    pub fn toHash(self: *Comment) *const [sha256.digest_length]u8 {
        var h = sha256.init(.{});
        h.update(self.author);
        h.update(self.message);
        h.update(std.mem.asBytes(&self.time));
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
        try w.writeAll(std.mem.asBytes(&self.time));
        try w.writeAll("\x00");
        switch (self.target) {
            .nos => {},
            .diff => |diff| {
                try w.writeAll(std.mem.asBytes(&diff));
                try w.writeAll("\x00");
            },
        }
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

pub fn open(a: Allocator, hash: []const u8) !Comment {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.comment", .{std.fmt.fmtSliceHexLower(hash)});
    var dir = try std.fs.cwd().openDir("data/messages", .{});
    defer dir.close();
    var file = try dir.openFile(filename, .{});
    defer file.close();
    return try Comment.readFile(a, file);
}

pub fn new(ath: []const u8, msg: []const u8) !Comment {
    var dir = try std.fs.cwd().openDir("data/messages", .{});
    defer dir.close();
    var c = Comment{
        .author = ath,
        .message = msg,
    };
    try c.writeNew(dir);

    return c;
}

test Comment {
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
              20, 139, 139, 116,  88, 163,  88, 180, 232, 197, 141, 210 , 53,  50,  30, 121,
             245, 206, 171, 202,  74,  18, 138, 175, 207, 242,  56, 240, 200,  15,  31, 135
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
        "148b8b7458a358b4e8c58dd235321e79f5ceabca4a128aafcff238f0c80f1f87.comment",
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
        },
        blob,
    );
    // zig fmt: on
}
