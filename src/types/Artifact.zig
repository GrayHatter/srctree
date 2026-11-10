repo: []const u8,
commit_sha: GitSha = .zeros,
state: State = .default,
created: i64 = 0,
updated: i64 = 0,
blob: []u8 = &.{},

const Artifact = @This();

pub const type_prefix = .artifact;
pub const type_version = 0;

const State = @import("common.zig").State;

const TypeIo = types.TypedIo(Artifact);

pub fn typeIdent(a: Artifact, w: *Io.Writer) !void {
    std.debug.assert(a.repo.len > 0);
    try w.print("{s}.{f}", .{ a.repo, std.fmt.alt(a.commit_sha, .fmtHex) });
}

pub const blank: Artifact = .{
    .index = 0,
    .filename = &.{},
    .repo = &.{},
};

pub fn new(repo: []const u8, sha: GitSha, io: Io) !Artifact {
    const now = Io.Clock.real.now(io).toSeconds();
    var art = Artifact{
        .repo = repo,
        .commit_sha = sha,
        .state = .default,
        .created = now,
        .updated = now,
    };
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

pub fn open(repo: []const u8, sha: GitSha, a: Allocator, io: Io) !Artifact {
    var artifact: Artifact = .blank;

    artifact.repo = repo;
    artifact.commit_sha = sha;

    var reader = TypeIo.loadData(&artifact, a, io) catch return error.FSFault;
    defer reader.file.close(io);
    TypeIo.read(&artifact, &reader);

    if (find(u8, reader.interface.buffer, "\n\n")) |start| {
        // FIXME check position in reader
        artifact.blob = reader.interface.buffer[start + 2 ..];
    }
}

test Artifact {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try types.init((try tempdir.dir.createDirPathOpen(io, "datadir", .{ .open_options = .{ .iterate = true } })), io);

    var art = try Artifact.new("srctree", .{ .hash = .{ .sha1 = @splat('A') } }, io);

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
        \\repo: srctree
        \\commit_sha: 4141414141414141414141414141414141414141
        \\state.closed: false
        \\state.draft: false
        \\state.embargoed: false
        \\state.locked: false
        \\state.removed: false
        \\created: 1744830464
        \\updated: 1744830464
        \\
        \\
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
const GitSha = types.GitSha;

const types = @import("../types.zig");
