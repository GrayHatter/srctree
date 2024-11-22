const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();

const Comment = @import("comment.zig");
const Delta = @import("delta.zig");
const State = Delta.State;

const Types = @import("../types.zig");

pub const Thread = @This();

pub const TYPE_PREFIX = "threads";
const THREADS_VERSION: usize = 0;
var datad: Types.Storage = undefined;

pub fn init(_: []const u8) !void {}
pub fn initType(stor: Types.Storage) !void {
    datad = stor;
}

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
            t.message_data = try reader.readAllAlloc(a, 0x8FFFF);
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

message_data: ?[]const u8 = null,
messages: ?[]Message = null,

pub const MessageTypes = enum {
    comment,
    unknown,
};

pub const Message = union(MessageTypes) {
    comment: Comment,
    unknown: void,
};

pub fn commit(self: Thread) !void {
    if (self.messages) |msgs| {
        // Make a best effort to save/protect all data
        for (msgs) |msg| switch (msg) {
            .comment => |cmt| cmt.commit() catch continue,
            .unknown => {},
        };
    }
    const file = try openFile(self.index);
    defer file.close();
    const writer = file.writer().any();
    try self.writeOut(writer);
}

fn writeOut(self: Thread, writer: std.io.AnyWriter) !void {
    try writer.writeInt(usize, THREADS_VERSION, endian);
    try writer.writeStruct(self.state);
    try writer.writeInt(i64, self.created, endian);
    try writer.writeInt(i64, self.updated, endian);
    try writer.writeAll(&self.delta_hash);

    if (self.messages) |msgs| {
        for (msgs) |*msg| switch (msg.*) {
            .comment => |*c| try writer.writeAll(c.toHash()),
            .unknown => {},
        };
    }
    try writer.writeAll("\x00");
}

// TODO mmap
pub fn readFile(a: std.mem.Allocator, idx: usize, reader: *std.io.AnyReader) !Thread {
    // TODO I hate this, but I'm prototyping, plz rewrite
    var thread: Thread = readVersioned(a, idx, reader) catch return error.InputOutput;
    try thread.loadMessages(a);
    return thread;
}

fn loadFromData(a: Allocator, cd: []const u8) ![]Message {
    if (cd.len < 32) {
        if (cd.len != 1) { // ignore single null
            std.debug.print("unexpected number in comment data {}\n", .{cd.len});
        }
        return &[0]Message{};
    }
    const count = cd.len / 32;
    if (count == 0) return &[0]Message{};
    const msgs = try a.alloc(Message, count);
    var data = cd[0..];
    for (msgs, 0..count) |*c, i| {
        c.* = .{ .comment = Comment.open(a, data[0..32]) catch |err| {
            std.debug.print(
                \\Error loading msg data {} of {}
                \\error: {} target {any}
                \\
            , .{ i, count, err, data[0..32] });
            data = data[32..];
            continue;
        } };
        data = data[32..];
    }
    return msgs;
}
pub fn loadMessages(self: *Thread, a: Allocator) !void {
    if (self.message_data) |cd| {
        self.messages = try loadFromData(a, cd);
    }
}

pub fn getMessages(self: Thread) ![]Message {
    if (self.messages) |c| return c;
    return error.NotLoaded;
}

pub fn addComment(self: *Thread, a: Allocator, c: Comment) !void {
    if (self.messages) |*messages| {
        if (a.resize(messages.*, messages.len + 1)) {
            messages.*.len += 1;
        } else {
            self.messages = try a.realloc(messages.*, messages.len + 1);
        }
    } else {
        self.messages = try a.alloc(Message, 1);
    }
    self.messages.?[self.messages.?.len - 1] = .{ .comment = c };
    self.updated = std.time.timestamp();
    try self.commit();
}

pub fn raze(self: Thread, a: std.mem.Allocator) void {
    //if (self.alloc_data) |data| {
    //    a.free(data);
    //}
    if (self.messages) |c| {
        a.free(c);
    }
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
