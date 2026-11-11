repo: []const u8,
commit_sha: GitSha = .zeros,
state: State = .default,
created: i64 = 0,
updated: i64 = 0,
bytes: []u8 = &.{},

const Artifact = @This();

pub const type_prefix = .artifact;
pub const type_version = 0;

const max_bytes: std.Io.Limit = .limited(128 * 1024 * 1024 * 1024);

pub fn typeIdent(a: Artifact, w: *Io.Writer) !void {
    std.debug.assert(a.repo.len > 0);
    try w.print("{s}.{f}", .{ a.repo, std.fmt.alt(a.commit_sha, .fmtHex) });
}

pub const blank: Artifact = .{
    .repo = &.{},
};

pub fn new(repo: []const u8, sha: GitSha, io: Io) !Artifact {
    const now = Io.Clock.real.now(io).toSeconds();
    //var art: Artifact = .blank;

    var b: [512]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&b);
    const aa = fba.allocator();
    if (open(repo, sha, aa, io)) |_| {
        return error.AlreadyExists;
    } else |e| switch (e) {
        error.NotFound => {},
        error.OutOfMemory => {},
        else => return e,
    }

    return .{
        .repo = repo,
        .commit_sha = sha,
        .state = .default,
        .created = now,
        .updated = now,
    };
}

const base64: std.base64.Base64Encoder = .init(std.base64.url_safe_alphabet_chars, '=');
pub fn commit(art: *const Artifact, r: *Io.Reader, io: Io) !void {
    var writer = try TypeIo.commitExtraSkip(art, io, &.{"bytes"});
    defer writer.file.close(io);
    var w_b: [2048]u8 = undefined;
    writer.interface.buffer = &w_b;
    defer writer.interface.flush() catch {};
    while (r.takeArray(48)) |line| {
        var b: [64]u8 = undefined;
        try writer.interface.writeAll(base64.encode(&b, line));
        try writer.interface.writeByte('\n');
    } else |err| switch (err) {
        error.EndOfStream => {
            if (r.bufferedLen() > 0) {
                var b: [64]u8 = undefined;
                try writer.interface.writeAll(base64.encode(&b, r.buffered()));
                r.tossBuffered();
                try writer.interface.writeByte('\n');
            } else return;
        },
        else => return err,
    }
}

pub fn open(repo: []const u8, sha: GitSha, a: Allocator, io: Io) !Artifact {
    var art: Artifact = .blank;
    art.repo = repo;
    art.commit_sha = sha;
    var reader = try TypeIo.loadData(&art, a, io);
    TypeIo.read(&art, &reader.interface);
    defer reader.file.close(io);
    art.bytes = reader.interface.buffered();
    return art;
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
    try art.commit(.ending, io);

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

const State = @import("common.zig").State;

const TypeIo = types.TypedIo(Artifact);
const types = @import("../types.zig");
