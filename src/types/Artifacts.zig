index: usize,
created: i64 = 0,
updated: i64 = 0,
state: State,
repo: []const u8,
source_hash: DefaultHash,
artifact_hash: DefaultHash,

const Artifact = @This();

pub const type_prefix = .artifact;
pub const type_version = 0;

const State = @import("common.zig").State;

const typeio = Types.readerWriter(Artifact, .{
    .hash = @splat(0),
    .state = 0,
    .target = undefined,
    .kind = undefined,
});
const writerFn = typeio.write;
const readerFn = typeio.read;
const Index = Types.Index(type_prefix);

pub fn new(repo: []const u8, io: Io) !Artifact {
    const idx: usize = try Index.nextExtra(repo, io);
    var m = Artifact{
        .index = idx,
        .hash = @splat(0),
        .state = 0,
        .repo = repo,
        .created = Io.Clock.real.now(io).toSeconds(),
        .updated = Io.Clock.real.now(io).toSeconds(),
    };
    _ = m.genHash();
    try m.commit(io);
    return m;
}

pub fn commit(art: Artifact, io: Io) !void {
    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, "{s}.{x}." ++ @tagName(type_prefix), .{ art.repo, art.index });
    const file = try Types.commit(type_prefix, filename, io);
    defer file.close(io);

    var w_b: [2048]u8 = undefined;
    var fd_writer = file.writer(io, &w_b);
    try writerFn(&art, &fd_writer.interface);
}

pub fn open(repo: []const u8, index: usize, a: Allocator, io: Io) !Artifact {
    const max = Index.currentExtra(repo, io) catch return error.FSFault;
    if (index > max) return error.DeltaDoesNotExist;

    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, "{s}.{x}." ++ @tagName(type_prefix), .{ repo, index });
    var reader = Types.loadDataReader(.deltas, filename, a, io) catch return error.FSFault;

    return readerFn(&reader);
}

pub fn genHash(msg: *Artifact) *const DefaultHash {
    std.debug.assert(std.mem.eql(u8, msg.hash[0..], &[_]u8{0} ** 32));
    var h = Sha256.init(.{});
    h.update(asBytes(&msg.target));
    h.update(asBytes(&msg.created));
    h.update(asBytes(&msg.updated));
    h.update(asBytes(&@intFromEnum(msg.kind)));
    h.final(&msg.hash);
    return &msg.hash;
}

test "comment" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var c = Artifact{
        .target = 0,
        .state = 0,
        .kind = .comment,
        .author = "grayhatter",
        .message = "test comment, please ignore",
        .hash = @splat(0),
    };

    const hash = c.genHash();
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x5A, 0x6E, 0x83, 0xD6, 0xDE, 0xC1, 0x97, 0x77, 0x8A, 0x73, 0x79, 0xBB, 0x32, 0x76, 0xDF, 0xF2,
        0xB3, 0x74, 0xBB, 0x02, 0x19, 0x45, 0xB0, 0x29, 0x44, 0xEF, 0x00, 0xDC, 0x91, 0x62, 0x29, 0x41,
    }, hash);

    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init(try tempdir.dir.createDirPathOpen(io, "datadir", .{ .open_options = .{ .iterate = true } }), io);

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.message", .{hash});
    try std.testing.expectEqualStrings(
        "5a6e83d6dec197778a7379bb3276dff2b374bb021945b02944ef00dc91622941.message",
        filename,
    );

    {
        var file = try Types.commit(type_prefix, filename, io);
        defer file.close(io);
        var w_b: [2048]u8 = undefined;
        var writer = file.writer(io, &w_b);
        try writerFn(&c, &writer.interface);
    }
    var reader = try Types.loadDataReader(type_prefix, filename, a, io);
    defer a.free(reader.buffer);

    const expected =
        \\# messages/0
        \\hash: 5a6e83d6dec197778a7379bb3276dff2b374bb021945b02944ef00dc91622941
        \\state: 0
        \\target: 0
        \\kind: comment
        \\created: 0
        \\updated: 0
        \\src_tz: 0
        \\author: grayhatter
        \\message: test comment, please ignore
        \\extra0: 0
        \\
        \\
    ;

    try std.testing.expectEqualStrings(expected, reader.buffer);
}

test Artifact {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init((try tempdir.dir.createDirPathOpen(io, "datadir", .{ .open_options = .{ .iterate = true } })), io);

    var c = try Artifact.new(type_prefix, 0, "author", "message", io);

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0x7ffffff);
    c.created = Io.Clock.real.now(io).toSeconds() & mask;
    c.updated = Io.Clock.real.now(io).toSeconds() & mask;
    // required to overwrite the timestamp
    c.hash = @splat(0);
    _ = c.genHash();
    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try writerFn(&c, &writer.writer);

    const v0_text =
        \\# messages/0
        \\hash: ec491fbb9d29b35270925653168a308e1d978fda0397d3993eb15990a1fcb80e
        \\state: 0
        \\target: 0
        \\kind: comment
        \\created: 1744830464
        \\updated: 1744830464
        \\src_tz: 0
        \\author: author
        \\message: message
        \\extra0: 0
        \\
        \\
    ;

    try std.testing.expectEqualStrings(v0_text, writer.written());
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const asBytes = std.mem.asBytes;
const DefaultHash = Types.DefaultHash;

const Types = @import("../types.zig");
