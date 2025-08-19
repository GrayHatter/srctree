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
messages: []Message = &.{},

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
    var thread = readerFn(data);

    if (indexOf(u8, data, "\n\n")) |start| {
        var list: std.ArrayListUnmanaged(Message) = .{};
        var itr = std.mem.splitScalar(u8, data[start + 2 ..], '\n');
        while (itr.next()) |next| {
            if (next.len != 64) continue;
            var msg_hash: Types.DefaultHash = undefined;
            for (0..32) |i| msg_hash[i] = parseInt(u8, next[i * 2 .. i * 2 + 2], 16) catch 0;
            const message = Message.open(a, msg_hash) catch |err| {
                std.debug.print("unable to load message {}\n", .{err});
                continue;
            };
            try list.append(a, message);
        }
        thread.messages = try list.toOwnedSlice(a);
    }

    return thread;
}

pub fn commit(thread: Thread) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.thread", .{thread.index});
    const file = try Types.commit(.thread, filename);
    defer file.close();
    var writer = file.writer();
    try writerFn(&thread, &writer);

    // Make a best effort to save/protect all data
    for (thread.messages) |msg| {
        msg.commit() catch continue;
        var hash_str: [@sizeOf(Types.DefaultHash) * 2 + 1]u8 = undefined;
        try writer.writeAll(
            bufPrint(&hash_str, "{}\n", .{fmtSliceHexLower(&msg.hash)}) catch unreachable,
        );
    }
}

pub fn addComment(thread: *Thread, a: Allocator, author: []const u8, message: []const u8) !void {
    const new_len = thread.messages.len + 1;
    if (thread.messages.len == 0) {
        thread.messages = try a.alloc(Message, 1);
    } else {
        if (a.resize(thread.messages, new_len)) {
            thread.messages.len = new_len;
        } else {
            thread.messages = try a.realloc(thread.messages, new_len);
        }
    }

    thread.messages[new_len - 1] = try .new(thread.index, author, message);
    thread.updated = std.time.timestamp();
    try thread.commit();
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
const bufPrint = std.fmt.bufPrint;
const indexOf = std.mem.indexOf;
const endian = builtin.cpu.arch.endian();
const sha256 = std.crypto.hash.sha2.Sha256;
const fmtSliceHexLower = std.fmt.fmtSliceHexLower;
const parseInt = std.fmt.parseInt;

pub const Message = @import("message.zig");
const Delta = @import("delta.zig");

const Types = @import("../types.zig");
