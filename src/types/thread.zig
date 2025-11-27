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

messages: ArrayList(Message) = .{},

const Thread = @This();

pub const type_prefix = "threads";
pub const type_version = 0;

pub fn new(delta: Delta, io: Io) !Thread {
    const max: usize = try Types.nextIndex(.thread, io);
    const thread = Thread{
        .index = max,
        .delta_hash = delta.hash,
        .created = (Io.Clock.now(.real, io) catch unreachable).toSeconds(),
        .updated = (Io.Clock.now(.real, io) catch unreachable).toSeconds(),
    };
    try thread.commit(io);
    return thread;
}

pub fn open(index: usize, a: Allocator, io: Io) !Thread {
    const max = try Types.currentIndex(.thread, io);
    if (index > max) return error.ThreadDoesNotExist;

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.thread", .{index});
    var reader = try Types.loadDataReader(.thread, filename, a, io);
    var thread = readerFn(&reader.interface);

    if (indexOf(u8, reader.interface.buffer, "\n\n")) |start| {
        var itr = std.mem.splitScalar(u8, reader.interface.buffer[start + 2 ..], '\n');
        while (itr.next()) |next| {
            if (next.len != 64) continue;
            var msg_hash: Types.DefaultHash = undefined;
            for (0..32) |i| msg_hash[i] = parseInt(u8, next[i * 2 .. i * 2 + 2], 16) catch 0;
            const message = Message.open(msg_hash, a, io) catch |err| {
                std.debug.print("unable to load message {}\n", .{err});
                continue;
            };
            try thread.messages.append(a, message);
        }
    }

    return thread;
}

pub fn commit(thread: Thread, io: Io) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.thread", .{thread.index});
    const file = try Types.commit(.thread, filename, io);
    defer file.close();

    var w_b: [2048]u8 = undefined;
    var fd_writer = file.writer(&w_b);
    const writer = &fd_writer.interface;
    try writerFn(&thread, writer);

    // Make a best effort to save/protect all data
    for (thread.messages.items) |msg| {
        msg.commit(io) catch continue;
        try writer.print("{x}\n", .{&msg.hash});
    }
    try writer.flush();
}

pub fn addComment(thread: *Thread, author: []const u8, message: []const u8, a: Allocator, io: Io) !void {
    try thread.addMessage(try .new(.comment, thread.index, author, message, io), a, io);
}

pub fn addMessage(thread: *Thread, m: Message, a: Allocator, io: Io) !void {
    try thread.messages.append(a, m);
    thread.updated = (Io.Clock.now(.real, io) catch unreachable).toSeconds();
    try thread.commit(io);
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

const typeio = Types.readerWriter(Thread, .{ .index = 0 });
const writerFn = typeio.write;
const readerFn = typeio.read;

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;
const bufPrint = std.fmt.bufPrint;
const indexOf = std.mem.indexOf;
const endian = builtin.cpu.arch.endian();
const sha256 = std.crypto.hash.sha2.Sha256;
const parseInt = std.fmt.parseInt;

const Message = @import("message.zig");
const Delta = @import("delta.zig");

const Types = @import("../types.zig");
