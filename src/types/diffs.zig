const std = @import("std");
const Allocator = std.mem.Allocator;

const Comments = @import("comments.zig");
const Comment = Comments.Comment;

pub const Diffs = @This();

const DIFF_VERSION: usize = 0;
const DIFF_VERSION_BYTES = @as(*const [8]u8, @ptrCast(&DIFF_VERSION));

fn readVersioned(idx: usize, data: []u8) !Diff {
    var int: usize = 0;
    @memcpy(@as(*[8]u8, @ptrCast(&int)), data[0..8]);
    var itr = std.mem.split(u8, data[8..], "\x00");
    return switch (int) {
        0 => return Diff{
            .index = idx,
            .file = undefined,
            .alloc_data = data,
            .repo = itr.first(),
            .title = itr.next().?,
            .source_uri = itr.next().?,
            .desc = itr.next().?,
            .comment_data = itr.rest(),
        },
        else => error.UnsupportedVersion,
    };
}

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
        try writer.writeAll(DIFF_VERSION_BYTES);
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
        var d = try readVersioned(idx, data);
        d.file = file;
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

var datad: std.fs.Dir = undefined;

pub fn init(dir: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}/diffs", .{dir});
    datad = try std.fs.cwd().openDir(filename, .{});
}

pub fn raze() void {
    datad.close();
}

fn currMaxSet(count: usize) !void {
    var cnt_file = try datad.createFile("_count", .{});
    defer cnt_file.close();
    var writer = cnt_file.writer();
    _ = try writer.writeIntNative(usize, count);
}

fn currMax() !usize {
    var cnt_file = try datad.openFile("_count", .{ .mode = .read_write });
    defer cnt_file.close();
    var reader = cnt_file.reader();
    const count: usize = try reader.readIntNative(usize);
    return count;
}

pub fn last() usize {
    return currMax() catch 0;
}

pub fn new(repo: []const u8, title: []const u8, src: []const u8, desc: []const u8) !Diff {
    var max: usize = currMax() catch 0;
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.diff", .{max + 1});
    var file = try datad.createFile(filename, .{});
    var d = Diff{
        .index = max + 1,
        .repo = repo,
        .title = title,
        .source_uri = src,
        .desc = desc,
        .file = file,
        .comment_data = "",
    };

    try currMaxSet(max + 1);

    return d;
}

pub fn open(a: std.mem.Allocator, index: usize) !?Diff {
    const max = currMax() catch 0;
    if (index > max) return null;

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.diff", .{index});
    var file = try datad.openFile(filename, .{ .mode = .read_write });
    return try Diff.readFile(a, index, file);
}
