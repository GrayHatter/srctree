src: Types.DefaultHash,
time: i64,
count: usize = 0,

viewers: ArrayList(View),

const Viewers = @This();

pub const empty: Viewers = .{
    .src = @splat(0),
    .time = 0,
    .count = 0,
    .viewers = .empty,
};

pub const View = struct {
    name: []const u8,
    time: i64,

    /// TODO name validation
    pub fn init(name: []const u8, time: i64) View {
        return .{
            .name = name,
            .time = time,
        };
    }

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

const typeio = Types.readerWriter(Viewers, .empty);
const writerFn = typeio.write;
const readerFn = typeio.read;
const Index = Types.Index(type_prefix);

pub fn new(src: Types.DefaultHash, viewer: []const u8, a: Allocator, io: Io) !Viewers {
    const views = try a.dupe(View, &.{
        .{ .name = viewer, .time = Io.Clock.real.now(io).toSeconds() },
    });
    var v: Viewers = .{
        .src = src,
        .time = views[0].time,
        .viewers = .{
            .items = views,
            .capacity = 1,
        },
    };

    try v.commit(io);
    return v;
}

pub fn newFrom(T: type, src: *const T, viewer: []const u8, a: Allocator, io: Io) !Viewers {
    switch (T) {
        Types.Delta => {
            var h = Types.DefaultHasher.init(.{});
            h.update(asBytes(&src.index));
            h.update(asBytes(&src.created));
            // may change
            h.update(src.repo);
            h.update(src.title);
            h.update(src.author orelse "");
            h.update(src.message);
            var hash: Types.DefaultHash = undefined;
            h.final(&hash);
            return .new(hash, viewer, a, io);
        },
        else => @compileError(@typeName(T) ++ " isn't implemented for Viewers.newFrom()"),
    }
}

/// Experimental API
pub fn promoteFrom(v: *Viewers, T: type, a: Allocator, io: Io) !void {
    var parent: *T = @fieldParentPtr("viewers", v);

    parent.viewers = try newFrom(T, parent, "", a, io);
}

pub fn open(src: Types.DefaultHash, a: Allocator, io: Io) !Viewers {
    var reader = try Types.loadDataHashId(type_prefix, src, a, io);
    var v: Viewers = readerFn(&reader);

    while (reader.takeSentinel('\n')) |line| {
        try v.viewers.append(a, View.parse(line) catch {
            log.err("line parse error in {x}", .{src});
            continue;
        });
    } else |err| switch (err) {
        error.EndOfStream => return v,
        error.ReadFailed => unreachable, // TODO validate{},
        error.StreamTooLong => unreachable, // TODO validate
    }
    return v;
}

pub fn commit(v: Viewers, io: Io) !void {
    if (v.count == 0) return;

    const file = try Types.commitHashId(type_prefix, v.src, io);
    defer file.close(io);
    var w_b: [2048]u8 = undefined;
    var writer = file.writer(io, &w_b);
    try writerFn(&v, &writer.interface);

    for (v.viewers.items) |viewer| {
        try writer.interface.print("{}:{s}\n", .{ viewer.time, viewer.name });
    }
    try writer.interface.flush();
}

pub fn inc(v: *Viewers, io: Io) void {
    v.count +|= 1;
    v.time = Io.Clock.real.now(io).toSeconds();
    v.commit(io) catch |err| {
        log.err("unable to commit viewers {} {any}", .{ err, v.src });
    };
}

pub fn view(v: *Viewers, name: []const u8, a: Allocator, io: Io) !void {
    if (v.viewers.items.len == 0) {
        const copy = try open(v.src, a, io);
        v.viewers = copy.viewers;
    }

    v.count +|= 1;
    const now = Io.Clock.real.now(io).toSeconds();
    try v.viewers.append(a, .init(name, now));
    v.time = now;
    try v.commit(io);
}

pub fn format(v: *const Viewers, w: *Io.Writer) !void {
    try w.print("hash={x} count={} time={}", .{ v.src, v.count, v.time });
}

test format {
    var buf: [200]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try format(&.{
        .src = @splat('B'),
        .count = 7,
        .time = 69420,
        .viewers = .empty,
    }, &w);

    const text = "hash=4242424242424242424242424242424242424242424242424242424242424242 count=7 time=69420";
    try std.testing.expectEqualStrings(text, w.buffered());
}

pub fn fromLine(line: [:'\n']const u8) !Viewers {
    var r: Io.Reader = .fixed(line);
    var next = try r.takeDelimiter(' ') orelse return error.InvalidLine;
    var hash: []const u8 = &.{};
    if (std.mem.cutPrefix(u8, next, "hash=")) |h| {
        hash = h;
    } else return error.InvalidLine;
    var src: [32]u8 = @splat(0);
    var zeros: usize = 0;
    if (hash.len == 64) {
        for (0..32) |i| {
            src[i] = std.fmt.parseInt(u8, hash[i * 2 ..][0..2], 16) catch 0;
            if (src[i] == 0) zeros += 1;
        } else if (zeros == 32) return .empty;
    } else return error.InvalidHash;

    var count: []const u8 = &.{};
    next = try r.takeDelimiter(' ') orelse return error.InvalidLine;
    if (std.mem.cutPrefix(u8, next, "count=")) |c| {
        count = c;
    } else return error.InvalidLine;

    var time: []const u8 = &.{};
    next = try r.takeDelimiter(' ') orelse return error.InvalidLine;
    if (std.mem.cutPrefix(u8, next, "time=")) |t| {
        time = t;
    } else return error.InvalidLine;

    return .{
        .src = src,
        .count = std.fmt.parseInt(usize, count, 0) catch 0,
        .time = std.fmt.parseInt(i64, time, 0) catch 0,
        .viewers = .empty,
    };
}

test fromLine {
    const text = "hash=4242424242424242424242424242424242424242424242424242424242424242 count=7 time=69420\n";
    const v: Viewers = try .fromLine(text[0 .. text.len - 1 :'\n']);
    try std.testing.expectEqualDeep(Viewers{
        .src = @splat('B'),
        .count = 7,
        .time = 69420,
        .viewers = .empty,
    }, v);
}

test Viewers {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init(
        (try tempdir.dir.createDirPathOpen(io, @tagName(type_prefix), .{ .open_options = .{ .iterate = true } })),
        io,
    );

    const mask: i64 = ~@as(i64, 0x7ffffff);
    const real = Io.Clock.real.now(io).toSeconds();
    const now = real & mask;
    var viewers = try Viewers.new(@splat('v'), "grayhatter", a, io);
    defer viewers.viewers.deinit(a);
    viewers.time = now;
    viewers.viewers.items[0].time = now;

    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try writerFn(&viewers, &writer.writer);

    for (viewers.viewers.items) |viewer|
        try writer.writer.print("{}:{s}\n", .{ viewer.time, viewer.name });
    try writer.writer.flush();

    const v1_text: []const u8 =
        \\# viewers/0
        \\src: 7676767676767676767676767676767676767676767676767676767676767676
        \\time: 1744830464
        \\count: 0
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
const asBytes = std.mem.asBytes;

const Types = @import("../types.zig");
