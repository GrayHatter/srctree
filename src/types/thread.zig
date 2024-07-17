const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();

const Comment = @import("comment.zig");
const Delta = @import("delta.zig");
const State = Delta.State;

pub const Thread = @This();

pub const TYPE_PREFIX = "{s}/threads";
const THREADS_VERSION: usize = 0;
pub var datad: std.fs.Dir = undefined;

pub fn init(_: []const u8) !void {}
pub fn initType() !void {}

fn readVersioned(a: Allocator, idx: usize, reader: *std.io.AnyReader) !Thread {
    const int: usize = try reader.readInt(usize, endian);
    return switch (int) {
        0 => {
            var t = Thread{
                .index = idx,
                .state = try reader.readStruct(State),
                .created = try reader.readInt(i64, endian),
                .updated = try reader.readInt(i64, endian),
            };
            _ = try reader.read(&t.delta_hash);
            t.comment_data = try reader.readAllAlloc(a, 0xFFFF);
            return t;
        },

        else => error.UnsupportedVersion,
    };
}

index: usize,
state: State = .{},
created: i64 = 0,
updated: i64 = 0,
delta_hash: [32]u8 = [_]u8{0} ** 32,
hash: [32]u8 = [_]u8{0} ** 32,

comment_data: ?[]const u8 = null,
comments: ?[]Comment = null,

pub fn writeOut(self: Thread) !void {
    const file = try openFile(self.index);
    defer file.close();
    const writer = file.writer().any();
    try writer.writeInt(usize, THREADS_VERSION, endian);
    try writer.writeStruct(self.state);
    try writer.writeInt(i64, self.created, endian);
    try writer.writeInt(i64, self.updated, endian);
    try writer.writeAll(&self.delta_hash);

    if (self.comments) |cmts| {
        for (cmts) |*c| {
            try writer.writeAll(c.toHash());
        }
    }
    try writer.writeAll("\x00");
}

// TODO mmap
pub fn readFile(a: std.mem.Allocator, idx: usize, reader: *std.io.AnyReader) !Thread {
    // TODO I hate this, but I'm prototyping, plz rewrite
    var thread: Thread = readVersioned(a, idx, reader) catch return error.InputOutput;
    try thread.loadComments(a);
    return thread;
}

pub fn loadComments(self: *Thread, a: Allocator) !void {
    if (self.comment_data) |cd| {
        self.comments = try Comment.loadFromData(a, cd);
    }
}

pub fn getComments(self: *Thread) ![]Comment {
    if (self.comments) |c| return c;
    return error.NotLoaded;
}

pub fn addComment(self: *Thread, a: Allocator, c: Comment) !void {
    if (self.comments) |*comments| {
        if (a.resize(comments.*, comments.len + 1)) {
            comments.*.len += 1;
        } else {
            self.comments = try a.realloc(comments.*, comments.len + 1);
        }
    } else {
        self.comments = try a.alloc(Comment, 1);
    }
    self.comments.?[self.comments.?.len - 1] = c;
    self.updated = std.time.timestamp();
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

fn currMaxSet(count: usize) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "_count", .{});
    var cnt_file = try datad.createFile(filename, .{});
    defer cnt_file.close();
    var writer = cnt_file.writer();
    _ = try writer.writeInt(usize, count, endian);
}

fn currMax() !usize {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "_count", .{});
    var cnt_file = try datad.openFile(filename, .{ .mode = .read_write });
    defer cnt_file.close();
    var reader = cnt_file.reader();
    const count: usize = try reader.readInt(usize, endian);
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

pub fn new(delta: Delta) !Thread {
    const max: usize = currMax() catch 0;
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.thread", .{max + 1});
    const file = try datad.createFile(filename, .{});
    defer file.close();
    try currMaxSet(max + 1);
    const thread = Thread{
        .index = max + 1,
        .delta_hash = delta.hash,
        .created = std.time.timestamp(),
        .updated = std.time.timestamp(),
    };

    return thread;
}

fn openFile(index: usize) !std.fs.File {
    var buf: [2048]u8 = undefined;
    const filename = std.fmt.bufPrint(&buf, "{x}.thread", .{index}) catch return error.InvalidTarget;
    return try datad.openFile(filename, .{ .mode = .read_write });
}

pub fn open(a: std.mem.Allocator, index: usize) !?Thread {
    const max = currMax() catch 0;
    if (index > max) return null;

    var file = openFile(index) catch return error.Other;
    defer file.close();
    var reader = file.reader().any();
    return try Thread.readFile(a, index, &reader);
}
