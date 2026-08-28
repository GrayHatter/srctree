index: usize,
created: i64 = 0,
updated: i64 = 0,
repo: []const u8,
title: []const u8,
message: []const u8,
author: ?[]const u8 = null,
//owner: []const u8 = &.{},
thread_id: usize = 0,
tags_id: usize = 0,

state: State = .default,
viewers: Viewers = .empty,
// TODO fix when unions are supported
attach: Attach = .nos,
attach_target: usize = 0,
attach_remote: []const u8 = &.{},

hash: [32]u8 = @splat(0),
thread: ?*Thread = null,

pub const Delta = @This();

pub const blank: Delta = .{
    .index = 0,
    .repo = &.{},
    .title = &.{},
    .message = &.{},
};

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

/// unstable api
pub const Attachment = union(Attach) {
    nos,
    diff: Types.Diff,
    issue,
    commit: []const u8,
    line: []const u8,
    remote: []const u8,
};

const typeio = Types.readerWriter(Delta, .blank);
const writerFn = typeio.write;
const readerFn = typeio.read;
const Index = Types.Index(type_prefix);

pub fn new(repo: []const u8, title: []const u8, msg: []const u8, author: []const u8, io: Io) !Delta {
    const now = Io.Clock.real.now(io).toSeconds();
    const max: usize = try Index.scoped.next(repo, io);
    var d = Delta{
        .index = max,
        .created = now,
        .updated = now,
        .repo = repo,
        .title = title,
        .message = msg,
        .author = author,
    };

    var thread: Thread = try .newDelta(d, io);
    try thread.commit(io);
    d.thread_id = thread.index;
    return d;
}

pub fn open(repo: []const u8, index: usize, a: Allocator, io: Io) !Delta {
    const max = Index.scoped.current(repo, io) catch return error.FSFault;
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
    defer file.close(io);
    var w_b: [2048]u8 = undefined;
    var fd_writer = file.writer(io, &w_b);
    try writerFn(&delta, &fd_writer.interface);
}

pub fn loadThread(delta: *Delta, a: Allocator, io: Io) !*Thread {
    if (delta.thread) |thr| return thr;
    const t = try a.create(Thread);
    t.* = Thread.open(delta.thread_id, a, io) catch |err| t: {
        log.err("Error loading thread!! {}", .{err});
        log.err(" old thread_id {};", .{delta.thread_id});
        const thread = Thread.newDelta(delta.*, io) catch |err2| {
            log.err(" unable to create new {}", .{err2});
            return error.UnableToLoadThread;
        };
        log.err("new thread_id {}", .{thread.index});
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

pub fn addComment(delta: *Delta, c: Comment, a: Allocator, io: Io) !Message {
    var thread: *Thread = delta.thread orelse try delta.loadThread(a, io);
    const msg = try thread.addComment(c.author, c.message, a, io);
    try thread.commit(io);
    delta.updated = Io.Clock.real.now(io).toSeconds();
    try delta.commit(io);
    return msg;
}

pub fn addMessage(delta: *Delta, m: Message, a: Allocator, io: Io) !void {
    var thread: *Thread = delta.thread orelse try delta.loadThread(a, io);
    try thread.addMessage(m, a, io);
    delta.updated = thread.updated;
    try delta.commit(io);
}

fn setCommon(delta: *Delta, comptime fmt: []const u8, c: Comment, a: Allocator, io: Io) !Message {
    var thread: *Thread = delta.thread orelse try delta.loadThread(a, io);
    var m: ?Message = null;
    if (c.message.len > 0)
        m = try thread.addComment(c.author, c.message, a, io);

    var b: [4096]u8 = undefined;
    const state_msg = try bufPrint(&b, fmt ++ " by {s}", .{c.author});
    try thread.addMessage(try .new(.state_change, delta.index, c.author, state_msg, io), a, io);
    delta.updated = thread.updated;
    try delta.commit(io);
    return m orelse return error.NoMessage;
}

pub fn setClosed(delta: *Delta, c: Comment, a: Allocator, io: Io) !Message {
    delta.state.closed = true;
    const m = try delta.setCommon("closed", c, a, io);
    return m;
}

pub fn setOpen(delta: *Delta, c: Comment, a: Allocator, io: Io) !Message {
    delta.state.closed = false;
    const m = try delta.setCommon("opened", c, a, io);
    return m;
}

pub const CommentsMeta = struct { count: usize, new: bool };

pub fn countComments(delta: Delta, io: Io) CommentsMeta {
    const thread = delta.thread orelse return .{ .count = 0, .new = false };
    const ts = Io.Clock.real.now(io).toSeconds() - 86400;
    var cmtnew: bool = false;
    var cmtlen: usize = 0;
    for (thread.messages.items) |m| switch (m.kind) {
        .comment => {
            cmtnew = cmtnew or m.updated > ts;
            cmtlen += 1;
        },
        .diff_update => cmtnew = cmtnew or m.updated > ts,
        .state_change => cmtnew = cmtnew or m.updated > ts,
    };
    return .{ .count = cmtlen, .new = cmtnew };
}

pub fn raze(_: Delta, _: std.mem.Allocator) void {
    // TODO implement raze
}

pub const Attached = union(enum) {
    nos,
    diff: Diff,
};

pub fn attached(d: *const Delta, a: Allocator, io: Io) !Attached {
    return switch (d.attach) {
        .nos => .nos,
        .commit => unreachable,
        .diff => .{ .diff = (try Diff.open(d.attach_target, a, io)) orelse return error.Missing },
        .issue => unreachable,
        .line => unreachable,
        .remote => unreachable,
    };
}

pub const Iterator = struct {
    dir: Io.Dir.Iterator,

    pub fn init(io: Io) Iterator {
        const dir: Io.Dir = Types.iterableDir(.deltas, io) catch unreachable;
        return .{
            .dir = dir.iterate(),
        };
    }

    pub fn next(self: *Iterator, a: Allocator, io: Io) ?Delta {
        const line = (self.dir.next(io) catch return null) orelse return null;
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
    _ = &std.testing.refAllDecls(Delta);

    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init((try tempdir.dir.createDirPathOpen(io, "delta", .{ .open_options = .{ .iterate = true } })), io);

    var d = try Delta.new("repo_name", "title", "message", "author", io);

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0x7ffffff);
    d.created = Io.Clock.real.now(io).toSeconds() & mask;
    d.updated = Io.Clock.real.now(io).toSeconds() & mask;
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
        \\state.draft: false
        \\state.embargoed: false
        \\state.locked: true
        \\state.removed: false
        \\viewers: hash=0000000000000000000000000000000000000000000000000000000000000000 count=0 time=0
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
const log = std.log.scoped(.srctree_type_delta);
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
const Diff = @import("Diff.zig");
const Viewers = @import("Viewers.zig");
