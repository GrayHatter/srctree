const std = @import("std");
const Allocator = std.mem.Allocator;

const Comments = @import("comments.zig");
const Comment = Comments.Comment;
const Deltas = @import("deltas.zig");

pub const Threads = @This();

const THREADS_VERSION: usize = 0;

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
        0 => {
            var t = Thread{
                .index = idx,
                .state = try reader.readIntNative(usize),
                .created = try reader.readIntNative(i64),
                .updated = try reader.readIntNative(i64),
                .file = file,
            };
            _ = try reader.read(&t.delta_hash);
            t.comment_data = try reader.readAllAlloc(a, 0xFFFF);
            return t;
        },

        else => error.UnsupportedVersion,
    };
}

pub const Thread = struct {
    index: usize,
    state: usize,
    created: i64 = 0,
    updated: i64 = 0,
    delta_hash: [32]u8 = [_]u8{0} ** 32,
    hash: [32]u8 = [_]u8{0} ** 32,

    comment_data: ?[]const u8 = null,
    comments: ?[]Comment = null,
    file: std.fs.File,

    pub fn writeOut(self: Thread) !void {
        try self.file.seekTo(0);
        var writer = self.file.writer();
        try writer.writeIntNative(usize, THREADS_VERSION);
        try writer.writeIntNative(usize, self.state);
        try writer.writeIntNative(i64, self.created);
        try writer.writeIntNative(i64, self.updated);
        try writer.writeAll(&self.delta_hash);

        if (self.comments) |cmts| {
            for (cmts) |*c| {
                try writer.writeAll(c.toHash());
            }
        }
        try writer.writeAll("\x00");
        try self.file.setEndPos(self.file.getPos() catch unreachable);
    }

    // TODO mmap
    pub fn readFile(a: std.mem.Allocator, idx: usize, file: std.fs.File) !Thread {
        // TODO I hate this, but I'm prototyping, plz rewrite
        file.seekTo(0) catch return error.InputOutput;
        var thread: Thread = readVersioned(a, idx, file) catch return error.InputOutput;
        return thread;
    }

    pub fn getComments(self: *Thread, a: Allocator) ![]Comment {
        if (self.comments) |_| return self.comments.?;

        if (self.comment_data) |cd| {
            self.comments = try Comments.loadFromData(a, cd);
            return self.comments.?;
        }
        std.debug.print("WARN: no comment data found\n", .{});
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

fn currMaxSet(count: usize) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "_count", .{});
    var cnt_file = try datad.createFile(filename, .{});
    defer cnt_file.close();
    var writer = cnt_file.writer();
    _ = try writer.writeIntNative(usize, count);
}

fn currMax() !usize {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "_count", .{});
    var cnt_file = try datad.openFile(filename, .{ .mode = .read_write });
    defer cnt_file.close();
    var reader = cnt_file.reader();
    const count: usize = try reader.readIntNative(usize);
    return count;
}

pub const Iterator = struct {
    index: usize = 0,
    alloc: Allocator,
    repo_name: []const u8,

    pub fn init(a: Allocator, name: []const u8) Iterator {
        return .{
            .alloc = a,
            .repo_name = name,
        };
    }

    pub fn next(self: *Iterator) !?Thread {
        defer self.index += 1;
        return open(self.alloc, self.repo_name, self.index);
    }

    pub fn raze(_: Iterator) void {}
};

pub fn iterator() Iterator {
    return Iterator.init();
}

pub fn last() usize {
    return currMax() catch 0;
}

pub fn new(delta: Deltas.Delta) !Thread {
    var max: usize = currMax() catch 0;
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.thread", .{max + 1});
    var file = try datad.createFile(filename, .{});
    try currMaxSet(max + 1);
    var thread = Thread{
        .index = max + 1,
        .state = 0,
        .file = file,
        .delta_hash = delta.hash,
    };

    return thread;
}

pub fn open(a: std.mem.Allocator, index: usize) !?Thread {
    const max = currMax() catch 0;
    if (index > max) return null;

    var buf: [2048]u8 = undefined;
    const filename = std.fmt.bufPrint(&buf, "{x}.thread", .{index}) catch return error.InvalidTarget;
    var file = datad.openFile(filename, .{ .mode = .read_write }) catch return error.Other;
    return try Thread.readFile(a, index, file);
}
