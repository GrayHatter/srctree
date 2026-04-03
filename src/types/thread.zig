index: usize,
created: i64 = 0,
updated: i64 = 0,
state: State = .default,
delta_hash: Types.DefaultHash = @splat(0),
hash: Types.DefaultHash = @splat(0),

messages: ArrayList(Message) = .{},

const Thread = @This();

pub const type_prefix = .thread;
pub const type_version = 0;

pub const State = @import("common.zig").State;

const Index = Types.Index(type_prefix);

pub fn new(delta: Delta, io: Io) !Thread {
    const max: usize = try Index.next(io);
    const thread = Thread{
        .index = max,
        .delta_hash = delta.hash,
        .created = Io.Clock.real.now(io).toSeconds(),
        .updated = Io.Clock.real.now(io).toSeconds(),
    };
    try thread.commit(io);
    return thread;
}

pub fn open(index: usize, a: Allocator, io: Io) !Thread {
    const max = try Index.current(io);
    if (index > max) return error.ThreadDoesNotExist;

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.thread", .{index});
    var reader = try Types.loadDataReader(.thread, filename, a, io);
    var thread = readerFn(&reader);

    if (indexOf(u8, reader.buffer, "\n\n")) |start| {
        var itr = std.mem.splitScalar(u8, reader.buffer[start + 2 ..], '\n');
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
    defer file.close(io);

    var w_b: [2048]u8 = undefined;
    var fd_writer = file.writer(io, &w_b);
    const writer = &fd_writer.interface;
    try writerFn(&thread, writer);

    // Make a best effort to save/protect all data
    for (thread.messages.items) |msg| {
        msg.commit(io) catch continue;
        try writer.print("{x}\n", .{&msg.hash});
    }
    try writer.flush();
}

pub fn addComment(thread: *Thread, author: []const u8, message: []const u8, a: Allocator, io: Io) !Message {
    const msg: Message = try .new(.comment, thread.index, author, message, io);
    try thread.addMessage(msg, a, io);
    return msg;
}

pub fn addMessage(thread: *Thread, m: Message, a: Allocator, io: Io) !void {
    try thread.messages.append(a, m);
    thread.updated = Io.Clock.real.now(io).toSeconds();
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

test Thread {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init(
        (try tempdir.dir.createDirPathOpen(io, @tagName(type_prefix), .{ .open_options = .{ .iterate = true } })),
        io,
    );

    var delta: Delta = undefined;
    delta.hash = @splat('d');
    var t = try Thread.new(delta, io);

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0x7ffffff);
    t.created = Io.Clock.real.now(io).toSeconds() & mask;
    t.updated = Io.Clock.real.now(io).toSeconds() & mask;

    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try writerFn(&t, &writer.writer);

    const v1_text: []const u8 =
        \\# thread/0
        \\index: 1
        \\created: 1744830464
        \\updated: 1744830464
        \\state.closed: false
        \\state.draft: false
        \\state.embargoed: false
        \\state.locked: false
        \\state.removed: false
        \\delta_hash: 6464646464646464646464646464646464646464646464646464646464646464
        \\hash: 0000000000000000000000000000000000000000000000000000000000000000
        \\
        \\
    ;

    try std.testing.expectEqualStrings(v1_text, writer.written());

    var r: Io.Reader = .fixed(writer.written());
    const read = readerFn(&r);
    try std.testing.expectEqualDeep(t, read);
}

const typeio = Types.readerWriter(Thread, .{ .index = 0 });
const writerFn = typeio.write;
const readerFn = typeio.read;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;
const indexOf = std.mem.indexOf;
const parseInt = std.fmt.parseInt;
const Types = @import("../types.zig");
const Message = @import("message.zig");
const Delta = @import("delta.zig");
