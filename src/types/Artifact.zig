index: usize,
repo: []const u8,
filename: []const u8,
state: State = .default,
created: i64 = 0,
updated: i64 = 0,
source_commit_hash: Hash = @splat(0),
artifact_hash: Hash = @splat(0),
blob: []u8 = &.{},

const Artifact = @This();

pub const type_prefix = .artifact;
pub const type_version = 0;

const State = @import("common.zig").State;

const TypeIo = types.TypedIo(Artifact);

pub fn typeIdent(a: Artifact, w: *Io.Writer) !void {
    try w.print("{d}", .{a.index});
}

pub const blank: Artifact = .{
    .index = 0,
    .filename = &.{},
    .repo = &.{},
};

pub fn new(repo: []const u8, filename: []const u8, blob: []u8, src_hash: Hash, io: Io) !Artifact {
    const idx: usize = try TypeIo.Index.scoped.next(repo, io);
    const now = Io.Clock.real.now(io).toSeconds();
    var art = Artifact{
        .index = idx,
        .repo = repo,
        .filename = filename,
        .state = .default,
        .created = now,
        .updated = now,
        .source_commit_hash = src_hash,
        .blob = blob,
    };
    art.genHash();
    try art.commit(io);
    return art;
}

pub fn commit(art_: *const Artifact, io: Io) !void {
    // Yes, I feel bad about this
    var art = art_.*;
    const blob = art_.blob;
    art.blob = &.{};

    var writer = try TypeIo.commitExtra(&art, io);
    defer writer.file.close(io);
    var w_b: [2048]u8 = undefined;
    writer.interface.buffer = &w_b;
    try writer.interface.writeAll(blob);
    try writer.interface.flush();
}

pub fn open(repo: []const u8, index: usize, a: Allocator, io: Io) !Artifact {
    const max = TypeIo.Index.scoped.current(repo, io) catch return error.FSFault;
    if (index > max) return error.DeltaDoesNotExist;

    var artifact: Artifact = .blank;

    artifact.index = index;
    artifact.repo = repo;

    var reader = TypeIo.loadData(&artifact, a, io) catch return error.FSFault;
    defer reader.file.close(io);
    TypeIo.read(&artifact, &reader);

    if (find(u8, reader.interface.buffer, "\n\n")) |start| {
        // FIXME check position in reader
        artifact.blob = reader.interface.buffer[start + 2 ..];
    }
}

pub fn genHash(art: *Artifact) void {
    Sha256.hash(art.blob, &art.artifact_hash, .{});
}

test Artifact {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try types.init((try tempdir.dir.createDirPathOpen(io, "datadir", .{ .open_options = .{ .iterate = true } })), io);

    var art = try Artifact.new("srctree", "blob.txt", @constCast("this is the blob"), @splat('A'), io);
    art.index = 0x10;

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0x7ffffff);
    art.created = Io.Clock.real.now(io).toSeconds() & mask;
    art.updated = Io.Clock.real.now(io).toSeconds() & mask;
    try art.commit(io);

    var reader = try TypeIo.loadData(&art, a, io);
    defer reader.file.close(io);
    defer a.free(reader.interface.buffer);

    const expected =
        \\# artifact/0
        \\index: 16
        \\repo: srctree
        \\filename: blob.txt
        \\state.closed: false
        \\state.draft: false
        \\state.embargoed: false
        \\state.locked: false
        \\state.removed: false
        \\created: 1744830464
        \\updated: 1744830464
        \\source_commit_hash: 4141414141414141414141414141414141414141414141414141414141414141
        \\artifact_hash: 3b84182326903ab652731619f265f6e6000e168734ba53c248a3b8b3b802e49c
        \\
        \\this is the blob
    ;

    try std.testing.expectEqualStrings(expected, reader.interface.buffered());
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const bufPrint = std.fmt.bufPrint;
const asBytes = std.mem.asBytes;
const find = std.mem.find;
const parseInt = std.fmt.parseInt;
const Hash = types.DefaultHash;

const types = @import("../types.zig");
