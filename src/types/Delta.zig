index: usize,
created: types.Timestamp = 0,
updated: types.Timestamp = 0,
repo: []const u8,
title: []const u8,
message: []const u8 = &.{},
author: ?[]const u8 = null,
//owner: []const u8 = &.{},
thread_id: usize = 0,
tags_id: usize = 0,

state: State = .default,
viewers: Viewers = .empty,
thread: Thread = .empty,
// TODO fix when unions are supported
attach: Attachment.Kind = .nos,
attach_target: usize = 0,
attach_remote: []const u8 = &.{},

hash: types.DefaultHash = @splat(0),

pub const Delta = @This();

pub const blank: Delta = .{
    .index = 0,
    .repo = &.{},
    .title = &.{},
    .message = &.{},
};

pub const type_prefix = .deltas;
pub const type_version = 0;

pub const RepoIterator = Search.RepoTypeIterator(Delta, TypeIo.Index, searchWrap);
pub const SearchIterator = Search.Iterator(Iterator);
pub const RepoSearchIterator = Search.Iterator(RepoIterator);
pub const TypeIo = types.TypedIo(Delta);

pub const Attachment = union(Kind) {
    nos,
    diff: types.Diff,
    issue,
    commit: []const u8,
    line: []const u8,
    remote: []const u8,

    pub const Kind = enum(u8) {
        nos = 0,
        diff = 1,
        issue = 2,
        commit = 3,
        line = 4,
        remote = 5,
    };
};

pub const Attached = union(enum) {
    nos,
    diff: Diff,
};

pub fn new(repo: []const u8, title: []const u8, msg: []const u8, author: []const u8, io: Io) !Delta {
    const now = Io.Clock.real.now(io).toSeconds();
    const max: usize = try TypeIo.Index.scoped.next(repo, io);

    var d = Delta{
        .index = max,
        .created = now,
        .updated = now,
        .repo = repo,
        .title = title,
        .message = msg,
        .author = author,
    };

    d.thread = try .new(Delta, &d, io);
    d.viewers = try .new(Delta, &d, io);
    return d;
}

pub fn open(repo: []const u8, index: usize, a: Allocator, io: Io) !Delta {
    log.debug("open Delta '{s}' .. {}", .{ repo, index });
    std.debug.assert(repo.len > 0);
    const max = TypeIo.Index.scoped.current(repo, io) catch @panic("IndexError");
    if (index > max) return error.DeltaDoesNotExist;

    var d: Delta = .blank;
    d.index = index;
    d.repo = repo;
    var reader = TypeIo.loadData(&d, a, io) catch return error.FSError;
    defer reader.file.close(io);
    TypeIo.read(&d, &reader.interface);
    return d;
}

pub fn commit(delta: Delta, io: Io) !void {
    delta.thread.commit(io) catch
        log.err("unable to save thread on delta 0x{x}", .{delta.index});
    delta.viewers.commit(io) catch
        log.err("unable to save viewers on delta 0x{x}", .{delta.index});
    try TypeIo.commit(&delta, io);
}

pub const Comment = struct {
    author: []const u8,
    message: []const u8,
};

fn setCommon(delta: *Delta, comptime fmt: []const u8, c: Comment, a: Allocator, io: Io) !Message {
    var m: ?Message = null;
    if (c.message.len > 0)
        m = try delta.thread.addComment(c.author, c.message, a, io);

    var b: [4096]u8 = undefined;
    const state_msg = try bufPrint(&b, fmt ++ " by {s}", .{c.author});
    try delta.thread.addMessage(try .new(.state_change, delta.index, c.author, state_msg, io), a, io);
    delta.updated = delta.thread.updated;
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

pub const CommentsMeta = struct {
    count: usize,
    new: bool,

    pub const zero: CommentsMeta = .{ .count = 0, .new = false };
};

pub fn attached(d: *const Delta, a: Allocator, io: Io) !Attached {
    return switch (d.attach) {
        .nos => .nos,
        .commit => unreachable,
        .diff => .{ .diff = (try Diff.open(d.attach_target, a, io)) },
        .issue => unreachable,
        .line => unreachable,
        .remote => unreachable,
    };
}

pub const Iterator = struct {
    fd: Io.Dir,
    dir: Io.Dir.Iterator,

    pub fn init(io: Io) Iterator {
        const dir: Io.Dir = TypeIo.iterableDir(io) catch unreachable;
        return .{
            .fd = dir,
            .dir = dir.iterate(),
        };
    }

    pub fn raze(itr: *const Iterator, io: Io) void {
        itr.fd.close(io);
    }

    pub fn next(self: *Iterator, a: Allocator, io: Io) ?Search.Hit {
        const line = (self.dir.next(io) catch return null) orelse return null;
        if (line.kind != .file) return self.next(a, io);
        log.debug("delta itr '{s}'", .{line.name});
        const cut = cutSuffix(u8, line.name, ".deltas") orelse return self.next(a, io);
        const i = findLast(u8, cut, ".") orelse return self.next(a, io);
        const num_str = cut[i + 1 ..];
        const name = cut[0..i];
        const num = parseInt(usize, num_str, 16) catch return self.next(a, io);
        const current = open(name, num, a, io) catch return self.next(a, io);
        return .{ .result = .{ .delta = current } };
    }
};

fn searchWrap(delta: Delta) Search.Hit.Result {
    return .{ .delta = delta };
}

pub fn typeIdent(d: Delta, w: *Io.Writer) !void {
    try w.print("{s}.{x}", .{ d.repo, d.index });
}
pub fn searchAll(rules: []const Search.Rule, io: Io) SearchIterator {
    return .{
        .rules = rules,
        .iterable = .init(io),
    };
}

pub fn searchRepo(repo: []const u8, rules: []const Search.Rule, io: Io) RepoSearchIterator {
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
    try types.init(
        (try tempdir.dir.createDirPathOpen(io, "deltas", .{ .open_options = .{ .iterate = true } })),
        io,
    );

    var d: Delta = try .new("repo_name", "title", "message", "author", io);
    d.index = 0x10;

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0x7ffffff);
    const nowish = Io.Clock.real.now(io).toSeconds() & mask;
    d.created = nowish;
    d.updated = nowish;
    d.state.locked = true;

    d.thread.src_hash = @splat('9');
    d.thread.updated = nowish;
    d.viewers.src = @splat('D');

    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try TypeIo.write(&d, &writer.writer);

    const v1_text: []const u8 =
        \\# deltas/0
        \\index: 16
        \\created: 1744830464
        \\updated: 1744830464
        \\repo: repo_name
        \\title: title
        \\message: message
        \\author: author
        \\thread_id: 0
        \\tags_id: 0
        \\state.closed: false
        \\state.draft: false
        \\state.embargoed: false
        \\state.locked: true
        \\state.removed: false
        \\viewers: hash=4444444444444444444444444444444444444444444444444444444444444444 count=0 time=0
        \\thread: idx=1 count=0 updated=1744830464 hash=3939393939393939393939393939393939393939393939393939393939393939
        \\attach: nos
        \\attach_target: 0
        \\hash: 0000000000000000000000000000000000000000000000000000000000000000
        \\
        \\
    ;

    try std.testing.expectEqualStrings(v1_text, writer.written());

    var r: Io.Reader = .fixed(writer.written());

    d.thread.created = 0;
    var read: Delta = .blank;
    read.repo = "repo_name";
    read.index = 1;
    TypeIo.read(&read, &r);
    try std.testing.expectEqualDeep(d, read);
}

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.srctypes_delta);
const Allocator = std.mem.Allocator;
const fs = std.fs;
const Io = std.Io;
const Writer = Io.Writer;
const findLast = std.mem.findLast;
const find = std.mem.find;
const endsWith = std.mem.endsWith;
const cutSuffix = std.mem.cutSuffix;
const eql = std.mem.eql;
const parseInt = std.fmt.parseInt;
const bufPrint = std.fmt.bufPrint;
const endian = builtin.cpu.arch.endian();

const State = @import("common.zig").State;
const Search = @import("../Search.zig");
const types = @import("../types.zig");
const Thread = types.Thread;
const Message = types.Message;
const Diff = @import("Diff.zig");
const Viewers = @import("Viewers.zig");
