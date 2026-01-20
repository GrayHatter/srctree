src: Types.DefaultHash,
time: i64,

viewers: ArrayList(View),

const Viewers = @This();

pub const View = struct {
    time: i64,
    name: []const u8,

    pub fn parse(line: [:'\n']const u8) !View {
        if (findScalar(u8, line, ':')) |idx| {
            return .{
                .time = try parseInt(i64, line[0..idx], 10),
                .name = line[idx + 1 ..],
            };
        }
        return error.InvalidViewLine;
    }
};

pub const type_prefix = .viewers;
pub const type_version: usize = 0;

const typeio = Types.readerWriter(Viewers, .{ .src = @splat(0), .viewers = .{}, .time = 0 });
const writerFn = typeio.write;
const readerFn = typeio.read;
const Index = Types.Index(type_prefix);

pub fn new(src: Types.DefaultHash, viewer: []const u8, io: Io) !Viewers {
    const now = (Io.Clock.now(.real, io) catch unreachable).toSeconds();
    var view: [1]View = .{
        .{ .time = now, .name = viewer },
    };
    var v: Viewers = .{
        .src = src,
        .time = now,
        .viewers = .{ .items = &view, .capacity = 1 },
    };

    try v.commit(io);
    return v;
}

pub fn open(src: Types.DefaultHash, a: Allocator, io: Io) !Viewers {
    var reader = try Types.loadDataHashId(type_prefix, src, a, io);
    var v: Viewers = try readerFn(&reader);

    while (reader.takeSentinel('\n')) |line| {
        try v.viewers.append(a, View.parse(line) catch {
            log.err("line parse error in {x}", .{src});
            continue;
        });
    } else |err| switch (err) {
        error.EndOfStream => return v,
    }
    return v;
}

pub fn commit(v: Viewers, io: Io) !void {
    const file = try Types.commitHashId(type_prefix, v.src, io);
    defer file.close();
    var w_b: [2048]u8 = undefined;
    var writer = file.writer(&w_b);
    try writerFn(&v, &writer.interface);

    for (v.viewers.items) |view| {
        try writer.interface.print("{}:{s}\n", .{ view.time, view.name });
    }
    try writer.interface.flush();
}

test Viewers {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init(
        (try tempdir.dir.makeOpenPath(@tagName(type_prefix), .{ .iterate = true })).adaptToNewApi(),
        io,
    );

    const mask: i64 = ~@as(i64, 0x7ffffff);
    const real = (try Io.Clock.now(.real, io)).toSeconds();
    const now = real & mask;
    var viewers = try Viewers.new(@splat('v'), "grayhatter", io);
    try std.testing.expectEqual(real, viewers.time);
    viewers.time = now;
    viewers.viewers = .{ .items = @constCast(&[1]View{.{ .time = now, .name = "grayhatter" }}), .capacity = 1 };

    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try writerFn(&viewers, &writer.writer);

    for (viewers.viewers.items) |view| {
        try writer.writer.print("{}:{s}\n", .{ view.time, view.name });
    }
    try writer.writer.flush();

    const v1_text: []const u8 =
        \\# viewers/0
        \\src: 7676767676767676767676767676767676767676767676767676767676767676
        \\time: 1744830464
        \\
        \\1744830464:grayhatter
        \\
    ;

    try std.testing.expectEqualStrings(v1_text, writer.written());

    var r: Io.Reader = .fixed(writer.written());
    const read = readerFn(&r);
    try std.testing.expectEqual(viewers.src, read.src);
}

const std = @import("std");
const log = std.log.scoped(.srctree_type_view);
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const findScalar = std.mem.findScalar;
const parseInt = std.fmt.parseInt;

const Types = @import("../types.zig");
