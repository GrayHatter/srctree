index: usize,
repo: []const u8,
filename: []const u8,
state: State = .default,
created: i64 = 0,
updated: i64 = 0,
source_commit_hash: DefaultHash = @splat(0),
artifact_hash: DefaultHash = @splat(0),
blob: []const u8 = &.{},

const Artifact = @This();

pub const type_prefix = .artifact;
pub const type_version = 0;

const State = @import("common.zig").State;

const typeio = Types.readerWriter(Artifact, .{
    .index = 0,
    .filename = &.{},
    .repo = &.{},
});
const writerFn = typeio.write;
const readerFn = typeio.read;
const Index = Types.Index(type_prefix);

pub fn new(repo: []const u8, filename: []const u8, blob: []const u8, src_hash: DefaultHash, io: Io) !Artifact {
    const idx: usize = try Index.nextExtra(repo, io);
    var art = Artifact{
        .index = idx,
        .repo = repo,
        .filename = filename,
        .state = .default,
        .created = Io.Clock.real.now(io).toSeconds(),
        .updated = Io.Clock.real.now(io).toSeconds(),
        .source_commit_hash = src_hash,
        .blob = blob,
    };
    art.genHash();
    try art.commit(io);
    return art;
}

pub fn commit(art_: Artifact, io: Io) !void {
    // Yes, I feel bad about this
    var art = art_;
    art.blob.len = 0;

    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, "{s}.{x}." ++ @tagName(type_prefix), .{ art.repo, art.index });
    const file = try Types.commit(type_prefix, filename, io);
    defer file.close(io);

    var w_b: [2048]u8 = undefined;
    var fd_writer = file.writer(io, &w_b);
    try writerFn(&art, &fd_writer.interface);

    try fd_writer.interface.writeAll(art_.blob);
    try fd_writer.interface.flush();
}

pub fn open(repo: []const u8, index: usize, a: Allocator, io: Io) !Artifact {
    const max = Index.currentExtra(repo, io) catch return error.FSFault;
    if (index > max) return error.DeltaDoesNotExist;

    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, "{s}.{x}." ++ @tagName(type_prefix), .{ repo, index });
    var reader = Types.loadDataReader(.deltas, filename, a, io) catch return error.FSFault;

    const artifact = readerFn(&reader);

    if (find(u8, reader.buffer, "\n\n")) |start| {
        // FIXME check position in reader
        artifact.blob = reader.buffer[start + 2 ..];
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
    try Types.init((try tempdir.dir.createDirPathOpen(io, "datadir", .{ .open_options = .{ .iterate = true } })), io);

    var art = try Artifact.new("srctree", "blob.txt", "this is the blob", @splat('A'), io);

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0x7ffffff);
    art.created = Io.Clock.real.now(io).toSeconds() & mask;
    art.updated = Io.Clock.real.now(io).toSeconds() & mask;
    try art.commit(io);

    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, "{s}.{x}." ++ @tagName(type_prefix), .{ art.repo, art.index });
    var reader = try Types.loadDataReader(type_prefix, filename, a, io);
    defer a.free(reader.buffer);

    const expected =
        \\# artifact/0
        \\index: 1
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

    try std.testing.expectEqualStrings(expected, reader.buffered());
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const asBytes = std.mem.asBytes;
const find = std.mem.find;
const parseInt = std.fmt.parseInt;
const DefaultHash = Types.DefaultHash;

const Types = @import("../types.zig");
