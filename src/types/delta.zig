index: usize,
//state: State = .{},
created: i64 = 0,
updated: i64 = 0,
repo: []const u8,
title: []const u8,
message: []const u8,
author: ?[]const u8 = null,
thread_id: usize = 0,
tags_id: usize = 0,

state: State = .default,
// TODO fix when unions are supported
attach: Attach = .nos,
attach_target: usize = 0,
attach_remote: []const u8 = &.{},

hash: [32]u8 = @splat(0),
thread: ?*Thread = null,

pub const Delta = @This();

pub const type_prefix = .deltas;
pub const type_version = 0;

pub const State = @import("common.zig").State;

pub const Attach = enum(u8) {
    nos = 0,
    diff = 1,
    issue = 2,
    commit = 3,
    line = 4,
    remote = 5,
};

const typeio = Types.readerWriter(Delta, .{
    .index = 0,
    .repo = &.{},
    .title = &.{},
    .message = &.{},
});
const writerFn = typeio.write;
const readerFn = typeio.read;
const Index = Types.Index(type_prefix);

pub fn new(repo: []const u8, title: []const u8, msg: []const u8, author: []const u8, io: Io) !Delta {
    const max: usize = try Index.nextExtra(repo, io);
    var d = Delta{
        .index = max,
        .created = (Io.Clock.now(.real, io) catch unreachable).toSeconds(),
        .updated = (Io.Clock.now(.real, io) catch unreachable).toSeconds(),
        .repo = repo,
        .title = title,
        .message = msg,
        .author = author,
    };

    var thread = try Thread.new(d, io);
    try thread.commit(io);
    d.thread_id = thread.index;
    return d;
}

pub fn open(repo: []const u8, index: usize, a: Allocator, io: Io) !Delta {
    const max = Index.currentExtra(repo, io) catch return error.FSFault;
    if (index > max) return error.DeltaDoesNotExist;

    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, "{s}.{x}.delta", .{ repo, index });
    var reader = Types.loadDataReader(.deltas, filename, a, io) catch return error.FSFault;
    return readerFn(&reader);
}

pub fn commit(delta: Delta, io: Io) !void {
    if (delta.thread) |thr| thr.commit(io) catch {}; // Save thread as best effort

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.{x}.delta", .{ delta.repo, delta.index });
    const file = try Types.commit(.deltas, filename, io);
    defer file.close();
    var w_b: [2048]u8 = undefined;
    var fd_writer = file.writer(&w_b);
    try writerFn(&delta, &fd_writer.interface);
}

pub fn loadThread(delta: *Delta, a: Allocator, io: Io) !*Thread {
    if (delta.thread) |thr| return thr;
    const t = try a.create(Thread);
    t.* = Thread.open(delta.thread_id, a, io) catch |err| t: {
        std.debug.print("Error loading thread!! {}", .{err});
        std.debug.print(" old thread_id {};", .{delta.thread_id});
        const thread = Thread.new(delta.*, io) catch |err2| {
            std.debug.print(" unable to create new {}\n", .{err2});
            return error.UnableToLoadThread;
        };
        std.debug.print("new thread_id {}\n", .{thread.index});
        delta.thread_id = thread.index;
        try delta.commit(io);
        break :t thread;
    };

    delta.thread = t;
    return t;
}

pub const Comment = struct {
    author: []const u8,
    message: []const u8,
};

pub fn addComment(delta: *Delta, c: Comment, a: Allocator, io: Io) !void {
    var thread: *Thread = delta.thread orelse try delta.loadThread(a, io);
    try thread.addComment(c.author, c.message, a, io);
    thread.messages.items[thread.messages.items.len - 1].extra0 = delta.attach_target;
    try thread.commit(io);
    delta.updated = (Io.Clock.now(.real, io) catch unreachable).toSeconds();
    try delta.commit(io);
}

pub fn addMessage(delta: *Delta, m: Message, a: Allocator, io: Io) !void {
    var thread: *Thread = delta.thread orelse try delta.loadThread(a, io);
    try thread.addMessage(m, a, io);
    delta.updated = thread.updated;
    try delta.commit(io);
}

pub const CommentsMeta = struct { count: usize, new: bool };

pub fn countComments(delta: Delta, io: Io) CommentsMeta {
    const thread = delta.thread orelse return .{ .count = 0, .new = false };
    const ts = (Io.Clock.now(.real, io) catch unreachable).toSeconds() - 86400;
    var cmtnew: bool = false;
    var cmtlen: usize = 0;
    for (thread.messages.items) |m| switch (m.kind) {
        .comment => {
            cmtnew = cmtnew or m.updated > ts;
            cmtlen += 1;
        },
        .diff_update => {
            cmtnew = cmtnew or m.updated > ts;
        },
    };
    return .{ .count = cmtlen, .new = cmtnew };
}

pub fn raze(_: Delta, _: std.mem.Allocator) void {
    // TODO implement raze
}

pub const Iterator = struct {
    dir: std.fs.Dir.Iterator,

    pub fn init(io: Io) Iterator {
        const dir: fs.Dir = .adaptFromNewApi(Types.iterableDir(.deltas, io) catch unreachable);
        return .{
            .dir = dir.iterate(),
        };
    }

    pub fn next(self: *Iterator, a: Allocator, io: Io) ?Delta {
        const line = (self.dir.next() catch return null) orelse return null;
        if (line.kind != .file) return self.next(a, io);
        const name = cutSuffix(u8, line.name, ".delta") orelse return self.next(a, io);
        const i = lastIndexOf(u8, name, ".") orelse return self.next(a, io);
        const num = parseInt(usize, name[i + 1 ..], 16) catch return self.next(a, io);
        const current = open(name[0..i], num, a, io) catch return self.next(a, io);
        return current;
    }
};

pub const RepoIterator = Tsearch.RepoIterator(Index, Delta);
pub const SearchIterator = Tsearch.Iterator(Iterator, Delta);
pub const RepoSearchIterator = Tsearch.Iterator(RepoIterator, Delta);

pub fn search(rules: []const Tsearch.Rule, io: Io) SearchIterator {
    return .{
        .rules = rules,
        .iterable = .init(io),
    };
}

pub fn searchRepo(repo: []const u8, rules: []const Tsearch.Rule, io: Io) RepoSearchIterator {
    return .{
        .rules = rules,
        .iterable = .init(repo, io),
    };
}
test Delta {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init((try tempdir.dir.makeOpenPath("delta", .{ .iterate = true })).adaptToNewApi(), io);

    var d = try Delta.new("repo_name", "title", "message", "author", io);

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0x7ffffff);
    d.created = (try Io.Clock.now(.real, io)).toSeconds() & mask;
    d.updated = (try Io.Clock.now(.real, io)).toSeconds() & mask;
    d.state.locked = true;

    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try writerFn(&d, &writer.writer);

    const v1_text: []const u8 =
        \\# deltas/0
        \\index: 1
        \\created: 1744830464
        \\updated: 1744830464
        \\repo: repo_name
        \\title: title
        \\message: message
        \\author: author
        \\thread_id: 1
        \\tags_id: 0
        \\state.closed: false
        \\state.locked: true
        \\state.embargoed: false
        \\attach: nos
        \\attach_target: 0
        \\hash: 0000000000000000000000000000000000000000000000000000000000000000
        \\
        \\
    ;

    try std.testing.expectEqualStrings(v1_text, writer.written());

    var r: Io.Reader = .fixed(writer.written());
    const read = readerFn(&r);
    try std.testing.expectEqualDeep(d, read);
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const Io = std.Io;
const Writer = Io.Writer;
const lastIndexOf = std.mem.lastIndexOf;
const indexOf = std.mem.indexOf;
const endsWith = std.mem.endsWith;
const cutSuffix = std.mem.cutSuffix;
const eql = std.mem.eql;
const parseInt = std.fmt.parseInt;
const bufPrint = std.fmt.bufPrint;
const endian = builtin.cpu.arch.endian();

const Types = @import("../types.zig");
const Thread = Types.Thread;
const Message = Types.Message;
const Tsearch = @import("search.zig");
