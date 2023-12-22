const std = @import("std");

const Allocator = std.mem.Allocator;
const sha256 = std.crypto.hash.sha2.Sha256;

pub const Comments = @This();

const Writer = std.fs.File.Writer;

const CMMT_VERSION: usize = 0;

pub fn charToKind(c: u8) TargetKind {
    if (c == 0) return .nos;
    unreachable;
}

fn readVersioned(a: Allocator, file: std.fs.File) !Comment {
    var reader = file.reader();
    var ver: usize = try reader.readIntNative(usize);
    return switch (ver) {
        0 => return Comment{
            .state = try reader.readIntNative(usize),
            .created = try reader.readIntNative(i64),
            .updated = try reader.readIntNative(i64),
            .tz = try reader.readIntNative(i32),
            .target = switch (try reader.readIntNative(u8)) {
                0 => .{ .diff = try reader.readIntNative(usize) },
                'D' => .{ .diff = try reader.readIntNative(usize) },
                'I' => .{ .issue = try reader.readIntNative(usize) },
                else => return error.CommentCorrupted,
            },
            .author = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .message = try reader.readAllAlloc(a, 0xFFFF),
        },
        else => error.UnsupportedVersion,
    };
}

pub const TargetKind = enum(u7) {
    nos = 0,
    commit = 'C',
    diff = 'D',
    issue = 'I',
    line_commit = 'l',
    line_diff = 'L',
};

pub const LineCommit = struct {
    number: usize,
    meta: usize,
};

pub const LineDiff = struct {
    file: usize,
    number: usize,
    revision: usize,
};

pub const Targets = union(TargetKind) {
    nos: void,
    commit: [20]u8,
    diff: usize,
    issue: usize,
    line_commit: LineCommit,
    line_diff: LineDiff,
};

pub const Comment = struct {
    state: usize = 0,
    created: i64 = 0,
    tz: i32 = 0,
    updated: i64 = 0,
    target: Targets = .{ .nos = {} },

    author: []const u8,
    message: []const u8,

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
        try self.writeStruct(w);
    }

    fn writeStruct(self: Comment, w: Writer) !void {
        try w.writeIntNative(usize, CMMT_VERSION);
        try w.writeIntNative(usize, self.state);
        try w.writeIntNative(i64, self.created);
        try w.writeIntNative(i64, self.updated);
        try w.writeIntNative(i32, self.tz);
        try w.writeIntNative(u8, @intFromEnum(self.target));
        switch (self.target) {
            .nos => try w.writeIntNative(usize, 0),
            .commit => |c| try w.writeAll(&c),
            .diff => try w.writeIntNative(usize, self.target.diff),
            .issue => try w.writeIntNative(usize, self.target.issue),
            .line_commit => unreachable,
            .line_diff => unreachable,
        }

        try w.writeAll(self.author);
        try w.writeAll("\x00");
        try w.writeAll(self.message);
    }

    pub fn readFile(a: std.mem.Allocator, file: std.fs.File) !Comment {
        return readVersioned(a, file);
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
            0x21, 0x78, 0x05, 0xE5, 0xB5, 0x0C, 0x05, 0xF5,
            0x22, 0xAC, 0xFE, 0xBA, 0xEA, 0xA4, 0xAC, 0xC2,
            0xD6, 0x50, 0xD1, 0xDD, 0x48, 0xFC, 0x34, 0x0E,
            0xBB, 0x53, 0x94, 0x60, 0x56, 0x93, 0xC9, 0xC8
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
              0,   0,   0,   0,   0,   0,   0,   0,
              0,   0,   0,   0,   0,   0,   0,   0,
              0,   0,   0,   0,   0,   0,   0,   0,
              0,   0,   0,   0,   0,   0,   0,   0,
              0,   0,   0,   0,   0,   0,   0,   0,
              0,   0,   0,   0,   0,
            103, 114,  97, 121, 104,  97, 116, 116, 101, 114,
              0, 116, 101, 115, 116,  32,  99, 111, 109, 109,
            101, 110, 116,  44,  32, 112, 108, 101,  97, 115,
            101,  32, 105, 103, 110, 111, 114, 101,
        },
        blob,
    );
    // zig fmt: on
}
