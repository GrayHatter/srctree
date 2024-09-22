const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();
const sha256 = std.crypto.hash.sha2.Sha256;
const allocPrint = std.fmt.allocPrint;
const Humanize = @import("../humanize.zig");

const Types = @import("../types.zig");

const Bleach = @import("../bleach.zig");
const Template = @import("../template.zig");

pub const Comment = @This();

const Writer = Types.Writer;

const CMMT_VERSION: usize = 0;

pub const TYPE_PREFIX = "{s}/messages";

pub var datad: std.fs.Dir = undefined;

pub fn init(_: []const u8) !void {}
pub fn initType() !void {}

pub fn raze() void {
    datad.close();
}

pub fn charToKind(c: u8) TargetKind {
    return switch (c) {
        'C' => .commit,
        'D' => .diff,
        'I' => .issue,
        'r' => .reply,
        else => .nos,
    };
}

fn readVersioned(a: Allocator, file: std.fs.File) !Comment {
    var reader = file.reader();
    const ver: usize = try reader.readInt(usize, endian);
    return switch (ver) {
        0 => return Comment{
            .state = try reader.readInt(usize, endian),
            .created = try reader.readInt(i64, endian),
            .updated = try reader.readInt(i64, endian),
            .tz = try reader.readInt(i32, endian),
            .target = switch (try reader.readInt(u8, endian)) {
                0 => .{ .diff = try reader.readInt(usize, endian) },
                'D' => .{ .diff = try reader.readInt(usize, endian) },
                'I' => .{ .issue = try reader.readInt(usize, endian) },
                'r' => .{ .reply = .{
                    .to = switch (try reader.readInt(u8, endian)) {
                        'c' => .{ .comment = try reader.readInt(usize, endian) },
                        'C' => .{ .commit = .{
                            .number = try reader.readInt(usize, endian),
                            .meta = try reader.readInt(usize, endian),
                        } },
                        'd' => .{ .diff = .{
                            .number = try reader.readInt(usize, endian),
                            .file = try reader.readInt(usize, endian),
                            .revision = try reader.readInt(usize, endian),
                        } },
                        else => return error.CommentCorrupted,
                    },
                } },
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
    reply = 'r',
};

/// Comments can be directly attached to a commit, or a diff, but are
/// replies when referencing a specific line/target within them.
const ReplyKinds = enum(u7) {
    nothing = 0,
    comment = 'c',
    commit = 'C',
    diff = 'd',
};

pub const Reply = struct {
    to: union(ReplyKinds) {
        nothing: void,
        comment: usize,
        commit: CommitLine,
        diff: DiffLine,
    },
};

pub const CommitLine = struct {
    number: usize,
    meta: usize,
};

pub const DiffLine = struct {
    number: usize,
    file: usize,
    revision: usize, // surely no one will ever need to use more than a u16
    // number of revisions... right? I'll just shrink this... WCGW?!
};

pub const Targets = union(TargetKind) {
    nos: void,
    commit: [20]u8,
    diff: usize,
    issue: usize,
    reply: Reply,
};

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
    const w = file.writer();
    try self.writeStruct(w);
}

fn writeStruct(self: Comment, w: Writer) !void {
    try w.writeInt(usize, CMMT_VERSION, endian);
    try w.writeInt(usize, self.state, endian);
    try w.writeInt(i64, self.created, endian);
    try w.writeInt(i64, self.updated, endian);
    try w.writeInt(i32, self.tz, endian);
    try w.writeInt(u8, @intFromEnum(self.target), endian);
    switch (self.target) {
        .nos => try w.writeInt(usize, 0, endian),
        .commit => |c| try w.writeAll(&c),
        .diff => try w.writeInt(usize, self.target.diff, endian),
        .issue => try w.writeInt(usize, self.target.issue, endian),
        .reply => unreachable,
    }

    try w.writeAll(self.author);
    try w.writeAll("\x00");
    try w.writeAll(self.message);
}

pub fn readFile(a: std.mem.Allocator, file: std.fs.File) !Comment {
    return readVersioned(a, file);
}

pub fn toContext(self: Comment, a: Allocator) !Template.Context {
    return Template.Context.initBuildable(a, self);
}

pub fn builder(self: Comment) Template.Context.Builder(Comment) {
    return Template.Context.Builder(Comment).init(self);
}

pub fn contextBuilder(self: Comment, a: Allocator, ctx: *Template.Context) !void {
    try ctx.putSlice("Author", try Bleach.sanitizeAlloc(a, self.author, .{}));
    try ctx.putSlice("Message", try Bleach.sanitizeAlloc(a, self.message, .{}));
    try ctx.putSlice("Date", try allocPrint(a, "{}", .{Humanize.unix(self.updated)}));
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
        .created = std.time.timestamp(),
        .updated = std.time.timestamp(),
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
    const comments = try a.alloc(Comment, count);
    for (comments, 0..) |*c, i| {
        c.* = try Comment.open(a, cd[i * 32 .. (i + 1) * 32]);
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
    const hash = c.toHash();
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
    const blob = try dir.dir.readFileAlloc(a, filename, 0xFF);
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
