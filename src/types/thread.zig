index: usize,
//state: State = .{},
created: i64 = 0,
updated: i64 = 0,
delta_hash: Types.DefaultHash = @splat(0),
hash: Types.DefaultHash = @splat(0),

closed: bool = false,
locked: bool = false,
embargoed: bool = false,
padding: u61 = 0,

message_data: ?[]const u8 = &.{},
messages: ?[]Message = null,

const Thread = @This();

pub const type_prefix = "threads";
pub const type_version = 0;

const typeio = Types.readerWriter(Thread, .{ .index = 0 });
const writerFn = typeio.write;
const readerFn = typeio.read;

pub fn new(delta: Delta) !Thread {
    const max: usize = try Types.nextIndex(.thread);
    const thread = Thread{
        .index = max,
        .delta_hash = delta.hash,
        .created = std.time.timestamp(),
        .updated = std.time.timestamp(),
    };
    try thread.commit();
    return thread;
}

pub fn open(a: std.mem.Allocator, index: usize) !Thread {
    const max = try Types.currentIndex(.thread);
    if (index > max) return error.ThreadDoesNotExist;

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.thread", .{index});
    const data = try Types.loadData(.thread, a, filename);
    return readerFn(data);
}

pub fn commit(thread: Thread) !void {
    if (thread.messages) |msgs| {
        // Make a best effort to save/protect all data
        for (msgs) |msg| msg.commit() catch continue;
    }

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.thread", .{thread.index});
    const file = try Types.commit(.thread, filename);
    defer file.close();
    var writer = file.writer();
    try writerFn(&thread, &writer);
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
        c.* = Message.open(a, data[0..32].*) catch |err| {
            std.debug.print(
                \\Error loading msg data {} of {}
                \\error: {} target {any}
                \\
            , .{ i, count, err, data[0..32] });
            data = data[32..];
            continue;
        };
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

pub fn newComment(self: *Thread, a: Allocator, author: []const u8, message: []const u8) !void {
    if (self.messages) |*messages| {
        if (a.resize(messages.*, messages.len + 1)) {
            messages.*.len += 1;
        } else {
            self.messages = try a.realloc(messages.*, messages.len + 1);
        }
    } else {
        self.messages = try a.alloc(Message, 1);
    }
    self.messages.?[self.messages.?.len - 1] = try Message.newComment(self.index, author, message);
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

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();
const sha256 = std.crypto.hash.sha2.Sha256;

pub const Message = @import("message.zig");
const Delta = @import("delta.zig");

const Types = @import("../types.zig");
