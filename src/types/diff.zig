const std = @import("std");
const Allocator = std.mem.Allocator;

const Comment = @import("comment.zig");
const Delta = @import("delta.zig");
const Thread = @import("thread.zig");

const Types = @import("../types.zig");

pub const Diff = @This();
pub const TYPE_PREFIX = "diffs";
const DIFF_VERSION: usize = 1;
var datad: std.fs.Dir = undefined;

pub fn init(_: []const u8) !void {}
pub fn initType(stor: Types.Storage) !void {
    datad = stor;
}

fn readVersioned(a: Allocator, idx: usize, file: std.fs.File) !Diff {
    var reader = file.reader();
    const ver: usize = try reader.readIntNative(usize);
    return switch (ver) {
        0 => return Diff{
            .index = idx,
            .state = try reader.readIntNative(usize),
            .created = try reader.readIntNative(i64),
            .updated = try reader.readIntNative(i64),
            .repo = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .binsha = null,
            .source_uri = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),

            .comment_data = try reader.readAllAlloc(a, 0xFFFF),
            .file = file,
        },
        1 => return Diff{
            .index = idx,
            .state = try reader.readIntNative(usize),
            .created = try reader.readIntNative(i64),
            .updated = try reader.readIntNative(i64),
            .repo = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .binsha = try reader.readBoundedBytes(20),
            .source_uri = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .applies = (try reader.readByte() > 0),
            .comment_data = try reader.readAllAlloc(a, 0xFFFF),
            .file = file,
        },
        else => error.UnsupportedVersion,
    };
}

index: usize,
state: usize,
created: i64 = 0,
updated: i64 = 0,
repo: []const u8,
binsha: ?[20]u8,
applies: bool = false,
delta_hash: [32]u8,
source_uri: ?[]const u8,

file: std.fs.File,

pub fn commit(self: Diff) !void {
    try self.file.seekTo(0);
    var writer = self.file.writer();
    try writer.writeIntNative(usize, DIFF_VERSION);
    try writer.writeIntNative(usize, self.state);
    try writer.writeIntNative(i64, self.created);
    try writer.writeIntNative(i64, self.updated);
    try writer.writeAll(self.repo);
    try writer.writeAll("\x00");
    try writer.writeAll(self.source_uri);
    try writer.writeAll("\x00");
    try self.file.setEndPos(self.file.getPos() catch unreachable);
}

pub fn readFile(a: std.mem.Allocator, idx: usize, file: std.fs.File) !Diff {
    var diff: Diff = try readVersioned(a, idx, file);
    var list = std.ArrayList(Comment).init(a);
    if (diff.comment_data) |cd| {
        const count = cd.len / 32;
        for (0..count) |i| {
            try list.append(Comment.open(a, cd[i * 32 .. (i + 1) * 32]) catch continue);
        }
        diff.comments = try list.toOwnedSlice();
    }
    return diff;
}

pub fn getComments(self: *Diff, a: Allocator) ![]Comment {
    if (self.comments) |_| return self.comments.?;

    if (self.comment_data) |cd| {
        self.comments = try Comment.loadFromData(a, cd);
    }
    return &[0]Comment{};
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
    //if (self.alloc_data) |data| {
    //    a.free(data);
    //}
    if (self.comments) |c| {
        a.free(c);
    }
    self.file.close();
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

pub fn forRepoCount(repo: []const u8) usize {
    //var itr = Threads.iterator(a, repo);

    //while (itr.next()) |next| {
    //    if (next) |nxt| {
    //        if (nxt.source != .diff) continue;
    //    }
    //} else |err| {
    //    std.debug.print("diff thread itr error {}\n", .{err});
    //    unreachable;
    //}

    var dir = datad.openIterableDir(".", .{}) catch {
        std.debug.print("Unable to open diff dir to get repo count\n", .{});
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
        const state: usize = reader.readIntNative(usize) catch continue;
        if (state != 0) continue;
        _ = reader.readIntNative(usize) catch continue; // created
        _ = reader.readIntNative(usize) catch continue; // updated
        var nbuf: [2048]u8 = undefined;
        const rname = reader.readUntilDelimiter(&nbuf, 0) catch continue;
        if (std.mem.eql(u8, rname, repo)) count += 1;
    }
    return count;
}

pub fn last() usize {
    return currMax() catch 0;
}

pub fn new(repo: []const u8, delta: Delta) !Diff {
    const max: usize = currMax() catch 0;
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.diff", .{max + 1});
    const file = try datad.createFile(filename, .{});
    const d = Diff{
        .index = max + 1,
        .state = 0,
        .repo = repo,
        .delta_hash = delta.hash,
        .source_uri = null,
        .file = file,
    };

    try currMaxSet(max + 1);

    return d;
}

pub fn open(a: std.mem.Allocator, index: usize) !?Diff {
    const max = currMax() catch 0;
    if (index > max) return null;

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.diff", .{index});
    const file = try datad.openFile(filename, .{ .mode = .read_write });
    return try Diff.readFile(a, index, file);
}
