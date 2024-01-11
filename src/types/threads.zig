const std = @import("std");
const Allocator = std.mem.Allocator;

const Comments = @import("comments.zig");
const Comment = Comments.Comment;

pub const Threads = @This();

const FILE_VERSION: usize = 0;

pub const Status = enum(u1) {
    open = 0,
    closed = 1,
};

/// while Zig specifies that the logical order of fields is little endian, I'm
/// not sure that's the layout I want to go use. So don't depend on that yet.
pub const State = packed struct {
    status: Status = .open,
    padding: u63 = 0,
};

pub const Source = enum(u8) {
    issue = 0,
    diff = 1,
    remote = 2, // indeterminate if remote sources can be supported within a
    // thread but for now they can be similar to an issue
};

test State {
    try std.testing.expectEqual(@sizeOf(State), @sizeOf(usize));

    const state = State{};
    const zero: usize = 0;
    const ptr: *const usize = @ptrCast(&state);
    try std.testing.expectEqual(zero, ptr.*);
}

fn readVersioned(a: Allocator, idx: usize, file: std.fs.File) !Thread {
    var reader = file.reader();
    var int: usize = try reader.readIntNative(usize);
    return switch (int) {
        0 => Thread{
            .index = idx,
            .state = try reader.readIntNative(usize),
            .created = try reader.readIntNative(i64),
            .updated = try reader.readIntNative(i64),
            .source = switch (try reader.readIntNative(u8)) {
                0 => .issue,
                1 => .diff,
                else => return error.InvalidThreadData,
            },
            .source_hash = try reader.readBytesNoEof(32),
            .repo = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .title = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .desc = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),

            .comment_data = try reader.readAllAlloc(a, 0xFFFF),
            .file = file,
        },
        else => error.UnsupportedVersion,
    };
}

pub const Thread = struct {
    index: usize,
    state: usize,
    created: i64 = 0,
    updated: i64 = 0,
    repo: []const u8,
    title: []const u8,
    desc: []const u8,
    source: Source = .issue,
    source_hash: [32]u8,

    comment_data: ?[]const u8,
    comments: ?[]Comment = null,
    file: std.fs.File,

    pub fn writeOut(self: Thread) !void {
        try self.file.seekTo(0);
        var writer = self.file.writer();
        try writer.writeIntNative(usize, FILE_VERSION);
        try writer.writeIntNative(usize, self.state);
        try writer.writeIntNative(i64, self.created);
        try writer.writeIntNative(i64, self.updated);
        try writer.writeIntNative(u8, @intFromEnum(self.source));
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

    pub fn readFile(a: std.mem.Allocator, idx: usize, file: std.fs.File) !Thread {
        try file.seekTo(0);
        var issue: Thread = try readVersioned(a, idx, file);
        return issue;
    }

    pub fn getComments(self: *Thread, a: Allocator) ![]Comment {
        if (self.comments) |_| return self.comments.?;

        if (self.comment_data) |cd| {
            self.comments = try Comments.loadFromData(a, cd);
        }
        return &[0]Comment{};
    }

    pub fn addComment(self: *Thread, a: Allocator, c: Comment) !void {
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

    pub fn raze(self: Thread, a: std.mem.Allocator) void {
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
    const filename = try std.fmt.bufPrint(&buf, "{s}/threads", .{dir});
    datad = std.fs.cwd().openDir(filename, .{}) catch |err| switch (err) {
        error.FileNotFound => try std.fs.cwd().makeOpenPath(filename, .{}),
        else => return err,
    };
}

pub fn raze() void {
    datad.close();
}

fn currMaxSet(repo: []const u8, count: usize) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "_{s}_count", .{repo});
    var cnt_file = try datad.createFile(filename, .{});
    defer cnt_file.close();
    var writer = cnt_file.writer();
    _ = try writer.writeIntNative(usize, count);
}

fn currMax(repo: []const u8) !usize {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "_{s}_count", .{repo});
    var cnt_file = try datad.openFile(filename, .{ .mode = .read_write });
    defer cnt_file.close();
    var reader = cnt_file.reader();
    const count: usize = try reader.readIntNative(usize);
    return count;
}

pub fn last(repo: []const u8) usize {
    return currMax(repo) catch 0;
}

pub fn new(repo: []const u8, title: []const u8, desc: []const u8, comptime src: Source) !Thread {
    var max: usize = currMax(repo) catch 0;
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.{x}.thread", .{ repo, max + 1 });
    var file = try datad.createFile(filename, .{});
    var d = Thread{
        .index = max + 1,
        .state = 0,
        .repo = repo,
        .title = title,
        .desc = desc,
        .file = file,
        .source = src,
        .source_hash = undefined,
        .comment_data = null,
    };

    try currMaxSet(repo, max + 1);

    return d;
}

pub fn open(a: std.mem.Allocator, repo: []const u8, index: usize) !?Thread {
    const max = currMax(repo) catch 0;
    if (index > max) return null;

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.{x}.thread", .{ repo, index });
    var file = try datad.openFile(filename, .{ .mode = .read_write });
    return try Thread.readFile(a, index, file);
}
