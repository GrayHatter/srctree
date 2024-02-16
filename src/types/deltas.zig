const std = @import("std");
const Allocator = std.mem.Allocator;

const Comments = @import("comments.zig");
const Comment = Comments.Comment;
const Threads = @import("threads.zig");
const Thread = Threads.Thread;

pub const Deltas = @This();

const DELTA_VERSION: usize = 0;

fn readVersioned(a: Allocator, idx: usize, file: std.fs.File) !Delta {
    var reader = file.reader();
    var ver: usize = try reader.readIntNative(usize);
    return switch (ver) {
        0 => return Delta{
            .index = idx,
            .state = try reader.readIntNative(usize),
            .created = try reader.readIntNative(i64),
            .updated = try reader.readIntNative(i64),
            .repo = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .title = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .desc = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .thread_id = try reader.readIntNative(usize),

            .file = file,
        },
        else => error.UnsupportedVersion,
    };
}

pub const Source = enum {
    nos,
};

pub const Delta = struct {
    index: usize,
    state: usize,
    created: i64 = 0,
    updated: i64 = 0,
    repo: []const u8,
    title: []const u8,
    desc: []const u8,
    hash: [32]u8 = [_]u8{0} ** 32,

    thread_id: usize = 0,
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
        // FIXME write 32 not a maybe
        if (self.thread) |thread| {
            try writer.writeAll(&thread.hash);
        }

        try writer.writeAll("\x00");
        try self.file.setEndPos(self.file.getPos() catch unreachable);
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

pub fn forRepoCount(repo: []const u8) usize {
    var dir = datad.openIterableDir(".", .{}) catch {
        std.debug.print("Unable to open delta dir to get repo count\n", .{});
        return 0;
    };
    defer dir.close();

    var diritr = dir.iterate();
    var count: usize = 0;
    while (diritr.next() catch return count) |f| {
        if (f.kind != .file) continue;
        //const index = std.fmt.parseInt(usize, file.name[0..file.name.len - 5], 16) catch continue;
        var file = datad.openFile(f.name, .{ .mode = .read_write }) catch continue;
        defer file.close();
        var reader = file.reader();
        _ = reader.readIntNative(usize) catch continue; // version
        var state: usize = reader.readIntNative(usize) catch continue;
        if (state != 0) continue;
        _ = reader.readIntNative(usize) catch continue; // created
        _ = reader.readIntNative(usize) catch continue; // updated
        var nbuf: [2048]u8 = undefined;
        var rname = reader.readUntilDelimiter(&nbuf, 0) catch continue;
        if (std.mem.eql(u8, rname, repo)) count += 1;
    }
    return count;
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
