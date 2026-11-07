name: []const u8,
title: []const u8 = &.{},
updated: types.Timestamp = 0,
visibility: Repo.Visibility = .public,
thread: Thread = .empty,
viewers: Viewers = .empty,

pub const RepoMeta = @This();

pub const empty: RepoMeta = .{
    .name = &.{},
};

pub const type_prefix = .repo_meta;
pub const type_version = 0;

const TypeIo = types.TypedIo(RepoMeta); //, "{s}.");

pub fn typeIdent(rm: RepoMeta, w: *Io.Writer) !void {
    try w.print("{s}", .{rm.name});
}

pub fn new(repo: []const u8, title: []const u8, io: Io) !RepoMeta {
    return .{
        .name = repo,
        .title = title,
        .updated = Io.Clock.real.now(io).toSeconds(),
    };
}

pub fn open(name: []const u8, a: Allocator, io: Io) !RepoMeta {
    var rm: RepoMeta = .empty;
    rm.name = name;
    var reader = try TypeIo.loadData(&rm, a, io);
    defer reader.file.close(io);
    TypeIo.read(&rm, &reader.interface);
    return rm;
}

pub fn commit(rm: *const RepoMeta, io: Io) !void {
    rm.thread.commit(io) catch {}; // Save thread as best effort
    try TypeIo.commit(rm, io);
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
    try TypeIo.write(&d, &writer.writer);

    const v1_text: []const u8 =
        \\# repo_meta/0
        \\name: repo_name
        \\title: title
        \\updated: 1744830464
        \\visibility: public
        \\thread: idx=0 count=0 updated=0 hash=0000000000000000000000000000000000000000000000000000000000000000
        \\viewers: hash=0000000000000000000000000000000000000000000000000000000000000000 count=0 time=0
        \\
        \\
    ;

    try std.testing.expectEqualStrings(v1_text, writer.written());

    var r: Io.Reader = .fixed(writer.written());
    var read: RepoMeta = .empty;
    read.name = "repo_name";

    TypeIo.read(&read, &r);
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
