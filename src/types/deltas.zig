const std = @import("std");
const Allocator = std.mem.Allocator;

const Types = @import("../types.zig");
const Comments = Types.Comments;
const Comment = Comments.Comment;
const Threads = Types.Threads;
const Thread = Threads.Thread;
const Template = @import("../template.zig");

pub const Deltas = @This();

const DELTA_VERSION: usize = 0;

fn readVersioned(a: Allocator, idx: usize, file: std.fs.File) !Delta {
    var reader = file.reader();
    var ver: usize = try reader.readIntNative(usize);
    var d: Delta = .{
        .index = idx,
        .repo = undefined,
        .title = undefined,
        .desc = undefined,
        .file = file,
    };
    switch (ver) {
        0 => {
            d.state = try reader.readIntNative(usize);
            d.created = try reader.readIntNative(i64);
            d.updated = try reader.readIntNative(i64);
            d.repo = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF);
            d.title = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF);
            d.desc = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF);
            d.thread_id = try reader.readIntNative(usize);
            d.attach = switch (Attach.fromInt(try reader.readIntNative(u8))) {
                .nos => .{ .nos = try reader.readIntNative(usize) },
                .diff => .{ .diff = try reader.readIntNative(usize) },
                .issue => .{ .issue = try reader.readIntNative(usize) },
            };
        },
        else => return error.UnsupportedVersion,
    }
    return d;
}

pub const Attach = enum(u8) {
    nos = 0,
    diff = 1,
    issue = 2,

    pub fn fromInt(int: u8) Attach {
        return switch (int) {
            1 => .diff,
            2 => .issue,
            else => .nos,
        };
    }
};

pub const Delta = struct {
    index: usize,
    state: usize = 0,
    created: i64 = 0,
    updated: i64 = 0,
    repo: []const u8,
    title: []const u8,
    desc: []const u8,
    thread_id: usize = 0,

    attach: union(Attach) {
        nos: usize,
        diff: usize,
        issue: usize,
    } = .{ .nos = 0 },
    hash: [32]u8 = [_]u8{0} ** 32,
    thread: ?*Thread = null,
    file: std.fs.File,

    pub fn writeOut(self: Delta) !void {
        try self.file.seekTo(0);
        var writer = self.file.writer();
        try writer.writeIntNative(usize, DELTA_VERSION);
        try writer.writeIntNative(usize, self.state);
        try writer.writeIntNative(i64, self.created);
        try writer.writeIntNative(i64, self.updated);
        try writer.writeAll(self.repo);
        try writer.writeAll("\x00");
        try writer.writeAll(self.title);
        try writer.writeAll("\x00");
        try writer.writeAll(self.desc);
        try writer.writeAll("\x00");
        try writer.writeIntNative(usize, self.thread_id);

        try writer.writeIntNative(u8, @intFromEnum(self.attach));
        switch (self.attach) {
            .nos => |att| try writer.writeIntNative(usize, att),
            .diff => |att| try writer.writeIntNative(usize, att),
            .issue => |att| try writer.writeIntNative(usize, att),
        }
        // FIXME write 32 not a maybe
        if (self.thread) |thread| {
            try writer.writeAll(&thread.hash);
        }

        try writer.writeAll("\x00");
        try self.file.setEndPos(self.file.getPos() catch unreachable);

        if (self.thread) |t| try t.writeOut();
    }

    pub fn readFile(a: std.mem.Allocator, idx: usize, file: std.fs.File) !Delta {
        var delta: Delta = try readVersioned(a, idx, file);
        return delta;
    }

    pub fn loadThread(self: *Delta, a: Allocator) !*const Thread {
        if (self.thread != null) return error.MemoryAlreadyLoaded;
        var t = try a.create(Thread);
        t.* = try Threads.open(a, self.thread_id) orelse return error.UnableToLoadThread;
        self.thread = t;
        return t;
    }

    pub fn getComments(self: *Delta, a: Allocator) ![]Comment {
        if (self.thread) |thread| {
            return thread.getComments(a);
        }
        return &[0]Comment{};
    }

    pub fn addComment(self: *Delta, a: Allocator, c: Comment) !void {
        if (self.thread) |thread| {
            return thread.addComment(a, c);
        }
        return error.ThreadNotLoaded;
    }

    pub fn builder(self: Delta) Template.Context.Builder(Delta) {
        return Template.Context.Builder(Delta).init(self);
    }

    pub fn raze(self: Delta, _: std.mem.Allocator) void {
        //if (self.alloc_data) |data| {
        //    a.free(data);
        //}
        self.file.close();
    }
};

var datad: std.fs.Dir = undefined;

pub fn init(dir: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}/deltas", .{dir});
    datad = try std.fs.cwd().makeOpenPath(filename, .{});
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

pub const Iterator = struct {
    alloc: Allocator,
    index: usize = 0,
    last: usize = 0,
    repo: []const u8,

    pub fn next(self: *Iterator) ?Delta {
        var buf: [2048]u8 = undefined;
        while (self.index <= self.last) {
            defer self.index +|= 1;
            const filename = std.fmt.bufPrint(&buf, "{s}.{x}.delta", .{ self.repo, self.index }) catch unreachable;
            var file = datad.openFile(filename, .{ .mode = .read_only }) catch continue;
            return Delta.readFile(self.alloc, self.index, file) catch continue;
        }
        return null;
    }
};

pub fn iterator(a: Allocator, repo: []const u8) Iterator {
    return .{
        .alloc = a,
        .repo = repo,
        .last = last(repo),
    };
}

pub fn last(repo: []const u8) usize {
    return currMax(repo) catch 0;
}

pub fn new(repo: []const u8) !Delta {
    // TODO this is probably a bug
    var max: usize = currMax(repo) catch 0;
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.{x}.delta", .{ repo, max + 1 });
    var file = try datad.createFile(filename, .{});
    try currMaxSet(repo, max + 1);

    var d = Delta{
        .index = max + 1,
        .state = 0,
        .repo = repo,
        .title = "",
        .desc = "",
        .file = file,
    };

    var thread = try Threads.new(d);
    try thread.writeOut();
    d.thread_id = thread.index;

    return d;
}

pub fn open(a: std.mem.Allocator, repo: []const u8, index: usize) !?Delta {
    const max = currMax(repo) catch 0;
    if (index > max) return null;

    var buf: [2048]u8 = undefined;
    const filename = std.fmt.bufPrint(&buf, "{s}.{x}.delta", .{ repo, index }) catch return error.InvalidTarget;
    var file = datad.openFile(filename, .{ .mode = .read_write }) catch return error.Other;
    return try Delta.readFile(a, index, file);
}
