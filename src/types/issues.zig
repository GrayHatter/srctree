const std = @import("std");
const Allocator = std.mem.Allocator;

const Comments = @import("comments.zig");
const Comment = Comments.Comment;

pub const Issues = @This();

const ISSUE_VERSION: usize = 0;

pub const Status = enum(u1) {
    open = 0,
    closed = 1,
};

pub const State = packed struct {
    status: Status = .open,
    padding: u63 = 0,
};

test State {
    try std.testing.expectEqual(@sizeOf(State), @sizeOf(usize));

    const state = State{};
    const zero: usize = 0;
    const ptr: *const usize = @ptrCast(&state);
    try std.testing.expectEqual(zero, ptr.*);
}

fn readVersioned(a: Allocator, idx: usize, file: std.fs.File) !Issue {
    var reader = file.reader();
    const int: usize = try reader.readIntNative(usize);
    return switch (int) {
        0 => Issue{
            .index = idx,
            .state = try reader.readIntNative(usize),
            .created = try reader.readIntNative(i64),
            .updated = try reader.readIntNative(i64),
            .repo = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .title = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .desc = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),

            .comment_data = try reader.readAllAlloc(a, 0xFFFF),
            .file = file,
        },
        else => error.UnsupportedVersion,
    };
}

pub const Issue = struct {
    index: usize,
    state: usize,
    created: i64 = 0,
    updated: i64 = 0,
    repo: []const u8,
    title: []const u8,
    desc: []const u8,

    comment_data: ?[]const u8,
    comments: ?[]Comment = null,
    file: std.fs.File,

    pub fn writeOut(self: Issue) !void {
        try self.file.seekTo(0);
        var writer = self.file.writer();
        try writer.writeIntNative(usize, ISSUE_VERSION);
        try writer.writeIntNative(usize, self.state);
        try writer.writeIntNative(i64, self.created);
        try writer.writeIntNative(i64, self.updated);
        try writer.writeAll(self.repo);
        try writer.writeAll("\x00");
        try writer.writeAll(self.title);
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

    pub fn readFile(a: std.mem.Allocator, idx: usize, file: std.fs.File) !Issue {
        try file.seekTo(0);
        const issue: Issue = try readVersioned(a, idx, file);
        return issue;
    }

    pub fn getComments(self: *Issue, a: Allocator) ![]Comment {
        if (self.comments) |_| return self.comments.?;

        if (self.comment_data) |cd| {
            self.comments = try Comments.loadFromData(a, cd);
        }
        return &[0]Comment{};
    }

    pub fn addComment(self: *Issue, a: Allocator, c: Comment) !void {
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

    pub fn raze(self: Issue, a: std.mem.Allocator) void {
        //if (self.alloc_data) |data| {
        //    a.free(data);
        //}
        if (self.comments) |c| {
            a.free(c);
        }
        self.file.close();
    }
};

var datad: std.fs.Dir = undefined;

pub fn init(dir: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}/issues", .{dir});
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

pub fn new(repo: []const u8, title: []const u8, desc: []const u8) !Issue {
    const max: usize = currMax() catch 0;
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.issue", .{max + 1});
    const file = try datad.createFile(filename, .{});
    const d = Issue{
        .index = max + 1,
        .state = 0,
        .repo = repo,
        .title = title,
        .desc = desc,
        .file = file,
        .comment_data = null,
    };

    try currMaxSet(max + 1);

    return d;
}

pub fn open(a: std.mem.Allocator, index: usize) !?Issue {
    const max = currMax() catch 0;
    if (index > max) return null;

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.issue", .{index});
    const file = try datad.openFile(filename, .{ .mode = .read_write });
    return try Issue.readFile(a, index, file);
}
