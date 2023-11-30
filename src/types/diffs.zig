const std = @import("std");
const Allocator = std.mem.Allocator;

const Comments = @import("comments.zig");
const Comment = Comments.Comment;

pub const Diffs = @This();

pub const Diff = struct {
    index: usize,
    repo: []const u8,
    title: []const u8,
    source_uri: []const u8,
    desc: []const u8,

    comment_data: []const u8,
    comments: ?[]Comment = null,
    file: std.fs.File,
    alloc_data: ?[]u8 = null,

    pub fn writeOut(self: Diff) !void {
        try self.file.seekTo(0);
        var writer = self.file.writer();
        try writer.writeAll(self.repo);
        try writer.writeAll("\x00");
        try writer.writeAll(self.title);
        try writer.writeAll("\x00");
        try writer.writeAll(self.source_uri);
        try writer.writeAll("\x00");
        try writer.writeAll(self.desc);
        try writer.writeAll("\x00");
        if (self.comments) |cmts| {
            for (cmts) |*c| {
                try writer.writeAll(c.toHash());
            }
        }
        try writer.writeAll("\x00");
        try self.file.setEndPos(self.file.getPos() catch unreachable);
    }

    pub fn readFile(a: std.mem.Allocator, idx: usize, file: std.fs.File) !Diff {
        const end = try file.getEndPos();
        var data = try a.alloc(u8, end);
        errdefer a.free(data);
        try file.seekTo(0);
        _ = try file.readAll(data);
        var itr = std.mem.split(u8, data, "\x00");
        var d = Diff{
            .index = idx,
            .file = file,
            .alloc_data = data,
            .repo = itr.first(),
            .title = itr.next().?,
            .source_uri = itr.next().?,
            .desc = itr.next().?,
            .comment_data = itr.rest(),
        };
        var list = std.ArrayList(Comment).init(a);
        const count = d.comment_data.len / 32;
        for (0..count) |i| {
            try list.append(try Comments.open(a, d.comment_data[i * 32 .. (i + 1) * 32]));
        }
        d.comments = try list.toOwnedSlice();
        return d;
    }

    pub fn getComments(self: *Diff, a: Allocator) ![]Comment {
        if (self.comments) |_| return self.comments.?;

        if (self.comment_data.len > 1 and self.comment_data.len < 32) {
            std.debug.print("unexpected number in comment data {}\n", .{self.comment_data.len});
            return &[0]Comment{};
        }
        const count = self.comment_data.len / 32;
        self.comments = try a.alloc(Comment, count);
        for (self.comments.?, 0..) |*c, i| {
            c.* = try Comments.open(a, self.comment_data[i * 32 .. (i + 1) * 32]);
        }
        return self.comments.?;
    }

    pub fn addComment(self: *Diff, a: Allocator, c: Comment) !void {
        const target = (self.comments orelse &[0]Comment{}).len;
        if (self.comments) |*comments| {
            if (a.resize(comments.*, target + 1)) {
                comments.*.len = target + 1;
            } else {
                self.comments = try a.realloc(comments.*, target + 1);
            }
        } else {
            self.comments = try a.alloc(Comment, target + 1);
        }
        self.comments.?[target] = c;
        try self.writeOut();
    }

    pub fn raze(self: Diff, a: std.mem.Allocator) void {
        if (self.alloc_data) |data| {
            a.free(data);
        }
        if (self.comments) |c| {
            a.free(c);
        }
        self.file.close();
    }
};

fn currMaxSet(dir: std.fs.Dir, count: usize) !void {
    var cnt_file = try dir.createFile("_count", .{});
    defer cnt_file.close();
    var writer = cnt_file.writer();
    _ = try writer.writeIntNative(usize, count);
}

fn currMax(dir: std.fs.Dir) !usize {
    var cnt_file = try dir.openFile("_count", .{ .mode = .read_write });
    defer cnt_file.close();
    var reader = cnt_file.reader();
    const count: usize = try reader.readIntNative(usize);
    return count;
}

pub fn last() !usize {
    var dir = try std.fs.cwd().openDir("data/diffs", .{});
    defer dir.close();

    return currMax(dir) catch 0;
}

pub fn new(repo: []const u8, title: []const u8, src: []const u8, desc: []const u8) !Diff {
    var dir = try std.fs.cwd().openDir("data/diffs", .{});
    defer dir.close();

    var max: usize = currMax(dir) catch 0;
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.diff", .{max + 1});
    var file = try dir.createFile(filename, .{});
    var d = Diff{
        .index = max + 1,
        .repo = repo,
        .title = title,
        .source_uri = src,
        .desc = desc,
        .file = file,
        .comment_data = "",
    };

    try currMaxSet(dir, max + 1);

    return d;
}

pub fn open(a: std.mem.Allocator, index: usize) !?Diff {
    var dir = try std.fs.cwd().openDir("data/diffs", .{});
    defer dir.close();

    const max = currMax(dir) catch 0;
    if (index > max) return null;

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.diff", .{index});
    var file = try dir.openFile(filename, .{ .mode = .read_write });
    return try Diff.readFile(a, index, file);
}