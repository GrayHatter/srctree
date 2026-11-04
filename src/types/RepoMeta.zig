name: []const u8,
title: []const u8 = &.{},
updated: types.Timestamp = 0,
visibility: Repo.Visibility = .public,
thread_id: usize = 0,

viewers: Viewers = .empty,
thread: ?*Thread = null,

pub const RepoMeta = @This();

pub const blank: RepoMeta = .{
    .name = &.{},
};

pub const type_prefix = .repo_meta;
pub const type_version = 0;

const typeio = types.readerWriter(RepoMeta, .blank);
const writerFn = typeio.write;
const readerFn = typeio.read;

pub fn new(repo: []const u8, title: []const u8, io: Io) !RepoMeta {
    var d = RepoMeta{
        .name = repo,
        .title = title,
        .updated = Io.Clock.real.now(io).toSeconds(),
    };

    var thread: Thread = try .new(RepoMeta, &d, io);
    try thread.commit(io);
    d.thread_id = thread.index;
    return d;
}

pub fn open(repo: []const u8, a: Allocator, io: Io) !RepoMeta {
    var reader = try types.loadReaderFmt(type_prefix, "{s}.", .{repo}, a, io);
    return readerFn(&reader);
}

pub fn commit(rm: RepoMeta, io: Io) !void {
    if (rm.thread) |thr| thr.commit(io) catch {}; // Save thread as best effort

    const file = try types.commitFmt(type_prefix, "{s}.", .{rm.name}, io);
    defer file.close(io);
    var w_b: [2048]u8 = undefined;
    var fd_writer = file.writer(io, &w_b);
    try writerFn(&rm, &fd_writer.interface);
}

pub fn loadThread(rm: *RepoMeta, a: Allocator, io: Io) !*Thread {
    if (rm.thread) |thr| return thr;
    const t = try a.create(Thread);
    t.* = Thread.open(rm.thread_id, a, io) catch |err| t: {
        log.err("Error loading thread!! {}", .{err});
        log.err(" old thread_id {};", .{rm.thread_id});
        const thread = Thread.new(RepoMeta, rm, io) catch |err2| {
            log.err(" unable to create new {}", .{err2});
            return error.UnableToLoadThread;
        };
        log.err("new thread_id {}", .{thread.index});
        rm.thread_id = thread.index;
        try rm.commit(io);
        break :t thread;
    };

    rm.thread = t;
    return t;
}

test RepoMeta {
    _ = &std.testing.refAllDecls(RepoMeta);

    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try types.init((try tempdir.dir.createDirPathOpen(io, "rm", .{ .open_options = .{ .iterate = true } })), io);

    var d = try RepoMeta.new("repo_name", "title", io);

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0x7ffffff);
    d.updated = Io.Clock.real.now(io).toSeconds() & mask;

    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try writerFn(&d, &writer.writer);

    const v1_text: []const u8 =
        \\# repo_meta/0
        \\name: repo_name
        \\title: title
        \\updated: 1744830464
        \\visibility: public
        \\thread_id: 1
        \\viewers: hash=0000000000000000000000000000000000000000000000000000000000000000 count=0 time=0
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
const log = std.log.scoped(.srctree_type_rm);
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

const Search = @import("../Search.zig");
const types = @import("../types.zig");
const Thread = types.Thread;
const Message = types.Message;
const Diff = @import("Diff.zig");
const Viewers = @import("Viewers.zig");
const Repo = @import("../Repo.zig");
