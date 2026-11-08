index: usize,
created: i64 = 0,
updated: i64 = 0,
count: usize = 0,
state: State = .default,
src_hash: Hash = @splat(0),
loaded: bool = false,

messages: ArrayList(Message) = .empty,

const Thread = @This();

pub const empty: Thread = .{ .index = 0 };

pub const type_prefix = .thread;
pub const type_version = 0;

pub const Hash = types.DefaultHash;
pub const Hasher = types.DefaultHasher;

const TypeIo = types.TypedIo(Thread);

pub fn typeIdent(t: Thread, w: *Io.Writer) !void {
    try w.print("{x}", .{t.index});
}

test typeIdent {
    var b: [30]u8 = undefined;
    const t: Thread = .{ .index = 0xFFDc };
    var w: Io.Writer = .fixed(&b);
    try typeIdent(t, &w);

    try std.testing.expectEqualStrings("ffdc", w.buffered());
}

pub fn new(T: type, src: *const T, io: Io) !Thread {
    const max: usize = try TypeIo.Index.next(io);
    const now = Io.Clock.real.now(io).toSeconds();

    var thread = Thread{
        .index = max,
        .created = now,
        .updated = now,
        .src_hash = @splat('7'),
    };

    switch (T) {
        types.Delta => {
            const d: *const types.Delta = src;
            var h: Hasher = .init(.{});
            h.update(asBytes(&d.index));
            h.update(asBytes(&d.created));
            // may change
            h.update(d.repo);
            h.update(d.title);
            h.update(d.author orelse "");
            h.update(d.message);
            h.final(&thread.src_hash);
        },
        types.RepoMeta => {
            const rm: *const types.RepoMeta = src;
            var h: Hasher = .init(.{});
            h.update(rm.name);
            h.final(&thread.src_hash);
        },
        types.CI => {
            const ci: *const types.CI = src;
            var h: Hasher = .init(.{});
            h.update(ci.repo);
            h.update(asBytes(&ci.index));
            h.update(asBytes(&ci.created));
            h.update(ci.trigger);
            h.final(&thread.src_hash);
        },
        //        types.RepoMeta => thread.src_hash = @splat('0'),
        //        types.CI => thread.src_hash = src.hash,
        else => @compileError(@typeName(T) ++ " isn't implemented for Viewers.newFrom()"),
    }

    try thread.commitNow(io);
    return thread;
}

pub fn load(t: *Thread, a: Allocator, io: Io) !void {
    log.debug("Thread load '{}' ", .{t.index});
    if (t.loaded) log.warn("Thread already loaded '{}' ", .{t.index});
    var reader = try TypeIo.loadData(t, a, io);
    defer reader.file.close(io);
    TypeIo.read(t, &reader.interface);

    while (reader.interface.takeSentinel('\n')) |line| {
        if (line.len != 64) continue;
        var msg_hash: Hash = undefined;
        for (0..32) |i| msg_hash[i] = parseInt(u8, line[i * 2 .. i * 2 + 2], 16) catch 0;
        try t.messages.append(a, Message.open(msg_hash, a, io) catch |err| {
            log.err("Thread {x} load unable to parse message {} '{any}'", .{ t.index, err, msg_hash });
            continue;
        });
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => log.err("Thread load message data corrupted {}", .{err}),
    }
    t.loaded = true;
}

pub fn commit(t: *const Thread, io: Io) !void {
    if (t.count == 0 or t.messages.items.len == 0) return;
    try t.commitNow(io);
}

fn commitNow(t: *const Thread, io: Io) !void {
    var writer = try TypeIo.commitExtra(t, io);
    defer writer.file.close(io);
    var w_b: [2048]u8 = undefined;
    writer.interface.buffer = &w_b;

    // Make a best effort to save/protect all data
    for (t.messages.items) |msg| {
        try writer.interface.print("{x}\n", .{&msg.hash});
        msg.commit(io) catch log.err("thread {} unable to commit message {any}", .{ t.index, msg });
    }
    try writer.interface.flush();
}

pub fn format(t: *const Thread, w: *Io.Writer) !void {
    try w.print("idx={X} count={d} updated={d} hash={x}", .{ t.index, t.count, t.updated, t.src_hash });
}

test format {
    var buf: [200]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try format(&.{
        .index = 4,
        .src_hash = @splat('B'),
        .count = 7,
        .updated = 69420,
    }, &w);

    const text = "idx=4 count=7 updated=69420 hash=4242424242424242424242424242424242424242424242424242424242424242";
    try std.testing.expectEqualStrings(text, w.buffered());
}

pub fn fromLine(line: [:'\n']const u8) !Thread {
    var r: Io.Reader = .fixed(line[0 .. line.len + 1]);
    var next = r.takeSentinel(' ') catch return error.InvalidLine;
    const index = cutPrefix(u8, next, "idx=") orelse return error.InvalidLine;
    next = r.takeSentinel(' ') catch return error.InvalidLine;
    const count = cutPrefix(u8, next, "count=") orelse return error.InvalidLine;
    next = r.takeSentinel(' ') catch return error.InvalidLine;
    const time = cutPrefix(u8, next, "updated=") orelse return error.InvalidLine;
    const last = r.takeSentinel('\n') catch return error.InvalidLine;
    const hash = cutPrefix(u8, last, "hash=") orelse return error.InvalidLine;

    var src: [32]u8 = @splat(0);
    if (hash.len == 64) {
        for (0..32) |i| {
            src[i] = parseInt(u8, hash[i * 2 ..][0..2], 16) catch return error.InvalidLine;
        }
    } else return error.InvalidHash;
    //std.debug.assert(!eql(u8, &@as([32]u8, @splat(0)), &src));

    return .{
        .index = parseInt(usize, index, 16) catch 999999999999999,
        .count = parseInt(usize, count, 0) catch 999999999999999,
        .updated = parseInt(i64, time, 0) catch 999999999999999,
        .src_hash = src,
    };
}

test fromLine {
    const text = "idx=AA88 count=7 updated=69420 hash=4242424242424242424242424242424242424242424242424242424242424242\n";
    const v: Thread = try .fromLine(text[0 .. text.len - 1 :'\n']);
    try std.testing.expectEqualDeep(Thread{
        .index = 0xaa88,
        .src_hash = @splat('B'),
        .count = 7,
        .updated = 69420,
    }, v);
}

pub fn addComment(t: *Thread, author: []const u8, message: []const u8, a: Allocator, io: Io) !Message {
    if (!t.loaded) unreachable;
    const msg: Message = try .new(.comment, t.index, author, message, io);
    log.debug("msg {any}", .{msg});
    try t.addMessage(msg, a, io);
    return msg;
}

pub fn addMessage(t: *Thread, m: Message, a: Allocator, io: Io) !void {
    if (!t.loaded) unreachable;
    try t.messages.append(a, m);
    t.count +|= 1;
    t.updated = Io.Clock.real.now(io).toSeconds();
    try t.commit(io);
}

pub fn raze(self: Thread, a: std.mem.Allocator) void {
    if (self.messages) |c| a.free(c);
}

test Thread {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try types.init(
        (try tempdir.dir.createDirPathOpen(io, @tagName(type_prefix), .{ .open_options = .{ .iterate = true } })),
        io,
    );

    //// LOL, you thought
    const mask: i64 = ~@as(i64, 0x7ffffff);
    const nowish = Io.Clock.real.now(io).toSeconds() & mask;

    var delta: Delta = .{
        .index = 9,
        .created = nowish,
        .repo = "blank",
        .title = "title",
    };
    delta.hash = @splat('d');
    var t = try Thread.new(Delta, &delta, io);
    t.created = nowish;
    t.updated = nowish;

    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try TypeIo.write(&t, &writer.writer);

    const v1_text: []const u8 =
        \\# thread/0
        \\index: 1
        \\created: 1744830464
        \\updated: 1744830464
        \\count: 0
        \\state.closed: false
        \\state.draft: false
        \\state.embargoed: false
        \\state.locked: false
        \\state.removed: false
        \\src_hash: 5febdc17f9472b0c3071b0dfbdca9820bb28cda180619461f70d945b0ab03f98
        \\loaded: false
        \\
        \\
    ;

    try std.testing.expectEqualStrings(v1_text, writer.written());

    var r: Io.Reader = .fixed(writer.written());
    var read: Thread = .empty;
    read.index = 1;
    TypeIo.read(&read, &r);
    try std.testing.expectEqualDeep(t, read);
}

const types = @import("../types.zig");
const State = types.State;
const Message = types.Message;
const Delta = types.Delta;
const std = @import("std");
const log = std.log.scoped(.srctypes_thread);
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;
const find = std.mem.find;
const parseInt = std.fmt.parseInt;
const asBytes = std.mem.asBytes;
const cutPrefix = std.mem.cutPrefix;
const eql = std.mem.eql;
