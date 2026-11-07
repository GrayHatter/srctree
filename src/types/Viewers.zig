src: Hash,
time: i64 = 0,
count: usize = 0,
viewers: ArrayList(View) = .empty,

const Viewers = @This();

pub const empty: Viewers = .{ .src = @splat(0) };
pub const type_prefix = .viewers;
pub const type_version: usize = 0;
pub const TypeIo = types.TypedIo(Viewers);
pub const Hash = types.DefaultHash;

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

pub fn new(T: type, src: *const T, io: Io) !Viewers {
    var viewers: Viewers = .empty;

    switch (T) {
        types.Delta => {
            var h = types.DefaultHasher.init(.{});
            h.update(asBytes(&src.index));
            h.update(asBytes(&src.created));
            // may change
            h.update(src.repo);
            h.update(src.title);
            h.update(src.author orelse "");
            h.update(src.message);
            h.final(&viewers.src);
        },
        void => viewers.src = @splat('T'),
        else => @compileError(@typeName(T) ++ " isn't implemented for Viewers.newFrom()"),
    }

    try viewers.commitNow(io);
    return viewers;
}

pub fn load(v: *Viewers, a: Allocator, io: Io) !void {
    var reader = try TypeIo.loadData(v, a, io);
    defer reader.file.close(io);
    TypeIo.read(v, &reader.interface);

    while (reader.interface.takeSentinel('\n')) |line| {
        try v.viewers.append(a, View.parse(line) catch {
            log.err("line parse error in {x}", .{v.src});
            continue;
        });
    } else |err| switch (err) {
        error.EndOfStream => return,
        error.ReadFailed => unreachable, // TODO validate{},
        error.StreamTooLong => unreachable, // TODO validate
    }
}

pub fn commit(v: *const Viewers, io: Io) !void {
    if (v.count == 0 or v.viewers.items.len == 0) return;
    try v.commitNow(io);
}

fn commitNow(v: *const Viewers, io: Io) !void {
    var writer = try TypeIo.commitExtra(v, io);
    defer writer.file.close(io);
    var w_b: [2048]u8 = undefined;
    writer.interface.buffer = &w_b;

    for (v.viewers.items) |viewer| {
        try writer.interface.print("{}:{s}\n", .{ viewer.time, viewer.name });
    }
    try writer.interface.flush();
}

pub fn view(v: *Viewers, name: []const u8, a: Allocator, io: Io) !void {
    if (v.viewers.items.len == 0) {
        try v.load(a, io);
    }

    v.count +|= 1;
    const now = Io.Clock.real.now(io).toSeconds();
    try v.viewers.append(a, .init(name, now));
    v.time = now;
    try v.commit(io);
}

pub fn typeIdent(v: Viewers, w: *Io.Writer) !void {
    try w.print("{x}", .{v.src});
}

pub fn format(v: *const Viewers, w: *Io.Writer) !void {
    try w.print("hash={x} count={d} time={d}", .{ v.src, v.count, v.time });
}

test format {
    var buf: [200]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try format(&.{
        .src = @splat('B'),
        .count = 7,
        .time = 69420,
    }, &w);

    const text = "hash=4242424242424242424242424242424242424242424242424242424242424242 count=7 time=69420";
    try std.testing.expectEqualStrings(text, w.buffered());
}

pub fn fromLine(line: [:'\n']const u8) !Viewers {
    var r: Io.Reader = .fixed(line);
    var next = try r.takeDelimiter(' ') orelse return error.InvalidLine;
    var hash: []const u8 = &.{};
    if (cutPrefix(u8, next, "hash=")) |h| {
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
    if (cutPrefix(u8, next, "count=")) |c| {
        count = c;
    } else return error.InvalidLine;

    var time: []const u8 = &.{};
    next = try r.takeDelimiter(' ') orelse return error.InvalidLine;
    if (cutPrefix(u8, next, "time=")) |t| {
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
    }, v);
}

test Viewers {
    const test_a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try types.init(
        (try tempdir.dir.createDirPathOpen(io, @tagName(type_prefix), .{ .open_options = .{ .iterate = true } })),
        io,
    );

    const mask: i64 = ~@as(i64, 0x7ffffff);
    var arena: std.heap.ArenaAllocator = .init(test_a);
    defer arena.deinit();
    const a = arena.allocator();

    const real = Io.Clock.real.now(io).toSeconds();
    const now = real & mask;

    var viewers: Viewers = try .new(void, &{}, io);
    defer viewers.viewers.deinit(a);
    viewers.time = now;

    try viewers.view("grayhatter", a, io);

    viewers.time = now;
    viewers.viewers.items[0].time = now;

    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try TypeIo.write(&viewers, &writer.writer);

    for (viewers.viewers.items) |viewer|
        try writer.writer.print("{}:{s}\n", .{ viewer.time, viewer.name });
    try writer.writer.flush();

    const v1_text: []const u8 =
        \\# viewers/0
        \\src: 5454545454545454545454545454545454545454545454545454545454545454
        \\time: 1744830464
        \\count: 1
        \\
        \\1744830464:grayhatter
        \\
    ;

    try std.testing.expectEqualStrings(v1_text, writer.written());

    var r: Io.Reader = .fixed(writer.written());
    var read: Viewers = .empty;
    TypeIo.read(&read, &r);
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
const cutPrefix = std.mem.cutPrefix;
const types = @import("../types.zig");
