header: Header,
filename_a: ?[]const u8,
filename_b: ?[]const u8,
stat: Stat,
bytes: []const u8,

const Diff = @This();

pub const Stat = struct {
    additions: u32,
    deletions: u32,
    total: isize,
};

pub const Line = union(enum) {
    hdr: Line.Header,
    add: Numbered,
    del: Numbered,
    ctx: Numbered,
    nul: void,

    pub const empty: Line = .{ .nul = {} };

    pub const Numbered = struct {
        number: u32,
        number_right: u32 = 0,
        text: []const u8,
        clean: bool = false,

        pub fn highlight(line: Line, lang: void) []const u8 {
            _ = line;
            _ = lang;
            return &.{};
        }

        pub fn format(num: Numbered, w: *Io.Writer) !void {
            if (num.clean) {
                try w.print("{s}", .{num.text});
            } else {
                try w.print("{f}", .{abx.Html.abx(num.text)});
            }
        }
    };

    pub const Header = struct {
        left: u32,
        right: u32,
        text: []const u8 = &.{},
        clean: bool = false,

        pub fn split(h: Line.Header) struct { u32, u32 } {
            return .{ h.left, h.right };
        }

        pub fn format(hdr: Line.Header, w: *Io.Writer) !void {
            if (hdr.clean) {
                try w.print("{s}", .{hdr.text});
            } else {
                try w.print("{f}", .{abx.Html.abx(hdr.text)});
            }
        }
    };
};

pub const FileType = enum(u4) {
    fifo = 0o1,
    character_device = 0o2,
    directory = 0o4,
    block_device = 0o6,
    regular_file = 0o10,
    symbolic_link = 0o12,
    socket = 0o14,
    // git specific
    submodule = 0o16,

    pub fn fromAscii(chr: [2]u8) !FileType {
        return switch (try std.fmt.parseInt(u16, &chr, 8)) {
            0o4 => .directory,
            0o10 => .regular_file,
            0o16 => .submodule,
            else => |int| {
                log.err("file type parse error {}", .{int});
                return error.InvalidMode;
            },
        };
    }
};

pub const FSPerm = packed struct(u3) {
    execute: bool = false,
    write: bool = false,
    read: bool = false,

    pub fn fromAscii(chr: u8) !FSPerm {
        return switch (chr) {
            '0' => .{ .read = false, .write = false, .execute = false },
            '1' => .{ .read = false, .write = false, .execute = true },
            '2' => .{ .read = false, .write = true, .execute = false },
            '3' => .{ .read = false, .write = true, .execute = true },
            '4' => .{ .read = true, .write = false, .execute = false },
            '5' => .{ .read = true, .write = false, .execute = true },
            '6' => .{ .read = true, .write = true, .execute = false },
            '7' => .{ .read = true, .write = true, .execute = true },
            else => error.InvalidMode,
        };
    }

    pub const none: FSPerm = .{ .read = false, .write = false, .execute = false };
    pub const r: FSPerm = .{ .read = true, .write = false, .execute = false };
    pub const rw: FSPerm = .{ .read = true, .write = true, .execute = false };
    pub const rwx: FSPerm = .{ .read = true, .write = true, .execute = true };
    pub const default: FSPerm = .{ .read = true, .write = false, .execute = false };
};

test FSPerm {
    var target: FSPerm = undefined;
    const modify: *u3 = @ptrCast(&target);
    modify.* = 7;
    try std.testing.expectEqual(true, target.read);
    try std.testing.expectEqual(true, target.write);
    try std.testing.expectEqual(true, target.execute);
}

pub const Mode = packed struct(u16) {
    other: FSPerm,
    group: FSPerm,
    owner: FSPerm,
    stick: FSPerm = .{},
    file_type: FileType,

    pub const default: Mode = .{
        .file_type = .regular_file,
        .owner = .rw,
        .group = .r,
        .other = .r,
    };

    pub fn fromStr(str: [6]u8) !Mode {
        return .{
            .other = try .fromAscii(str[5]),
            .group = try .fromAscii(str[4]),
            .owner = try .fromAscii(str[3]),
            .stick = try .fromAscii(str[2]),
            .file_type = try .fromAscii(str[0..2].*),
        };
    }

    test fromStr {
        {
            const m: Mode = try .fromStr("100444".*);
            try std.testing.expectEqual(
                Mode{ .other = .r, .group = .r, .owner = .r, .file_type = .regular_file },
                m,
            );
        }
        {
            const m: Mode = try .fromStr("100644".*);
            try std.testing.expectEqual(
                Mode{ .other = .r, .group = .r, .owner = .rw, .file_type = .regular_file },
                m,
            );
        }
        {
            const m: Mode = try .fromStr("040444".*);
            try std.testing.expectEqual(
                Mode{ .other = .r, .group = .r, .owner = .r, .file_type = .directory },
                m,
            );
        }
        {
            const m: Mode = try .fromStr("100777".*);
            try std.testing.expectEqual(
                Mode{ .other = .rwx, .group = .rwx, .owner = .rwx, .file_type = .regular_file },
                m,
            );
        }
        {
            const m: Mode = try .fromStr("160000".*);
            try std.testing.expectEqual(
                Mode{ .other = .none, .group = .none, .owner = .none, .file_type = .submodule },
                m,
            );
        }
    }
};

/// I haven't seen enough patches to know this is correct, but ideally
/// (assumably) for non merge commits a single change type should be
/// exhaustive? TODO find counter example and create test.
pub const Header = struct {
    bytes: []const u8,
    /// Header pretends to be an iterator
    idx: usize = 0,

    const Change = union(enum) {
        none: void,
        binary: void,
        newfile: Mode,
        deletion: Mode,
        copy: SrcDst,
        rename: SrcDst,
        mode: Mode,
        similarity: []const u8,
        dissimilarity: []const u8,

        const SrcDst = struct {
            src: []const u8,
            dst: []const u8,
        };

        pub fn parseLine(line: []const u8) !Change {
            if (startsWith(u8, line, "similarity index")) {
                // TODO parse similarity correctly
                return .{ .similarity = line };
            } else if (startsWith(u8, line, "old mode ")) {
                return .{ .mode = try .fromStr(line["old mode ".len..][0..6].*) };
            } else if (startsWith(u8, line, "new mode ")) {
                return .{ .mode = try .fromStr(line["new mode ".len..][0..6].*) };
            } else if (startsWith(u8, line, "deleted file mode ")) {
                return .{ .deletion = try .fromStr(line["deleted file mode ".len..][0..6].*) };
            } else if (startsWith(u8, line, "new file mode ")) {
                return .{ .newfile = try .fromStr(line["new file mode ".len..][0..6].*) };
            } else if (startsWith(u8, line, "copy from ")) {
                return .{ .copy = .{
                    .src = line["copy from ".len..],
                    .dst = undefined,
                } };
            } else if (startsWith(u8, line, "copy to ")) {
                return .{ .copy = .{
                    .src = line["copy to ".len..],
                    .dst = line["copy to ".len..],
                } };
            } else if (startsWith(u8, line, "rename from ")) {
                return .{ .rename = .{
                    .src = line["rename from ".len..],
                    .dst = undefined,
                } };
            } else if (startsWith(u8, line, "rename to ")) {
                return .{ .rename = .{
                    .src = undefined,
                    .dst = line["rename to ".len..],
                } };
            } else if (startsWith(u8, line, "dissimilarity index ")) {
                return .{ .dissimilarity = line };
            } else if (startsWith(u8, line, "Binary files ")) {
                return .{ .binary = {} };
            }
            return error.UnsupportedHeader;
        }
    };
};

//if (header.index != null and header.change != .newfile) {
//    // TODO redact and user headers
//    // Left Filename
//    diff.filename = try reader.takeDelimiter('\n') orelse
//        return error.UnableToParsePatchHeader;
//    if (!startsWith(u8, diff.filename.?, "--- ")) return error.UnableToParsePatchHeader;
//    diff.filename = diff.filename.?[4..];
//    diff.filename = if (eql(u8, diff.filename.?, "/dev/null"))
//        null
//    else
//        diff.filename.?[2..diff.filename.?.len];

//    if (diff.filename == null) {
//        diff.filename = try reader.takeDelimiter('\n') orelse
//            return error.UnableToParsePatchHeader;
//        if (!startsWith(u8, diff.filename.?, "+++ ")) return error.UnableToParsePatchHeader;
//        diff.filename = diff.filename.?[4..];
//        diff.filename = if (eql(u8, diff.filename.?, "/dev/null"))
//            null
//        else
//            diff.filename.?[2..diff.filename.?.len];
//    } else if (!startsWith(u8, try reader.takeDelimiter('\n') orelse
//        return error.UnableToParsePatchHeader, "+++ "))
//        return error.UnableToParsePatchHeader;

//    // Block headers
//    if (reader.peekDelimiterInclusive('\n')) |block| {
//        if (!startsWith(u8, block, "@@ -") or find(u8, block, " @@") == null)
//            return error.BlockHeaderMissing;
//    } else |err| switch (err) {
//        error.EndOfStream => return reader.buffered(),
//        error.ReadFailed => return error.ReadFailed,
//        error.StreamTooLong => return error.StreamTooLong,
//        // return error.UnableToParsePatchHeader;
//    }
//}

pub fn init(r: *Reader) !Diff {
    const blob = r.buffered();
    var len: usize = 0;
    var add: u32 = 0;
    var del: u32 = 0;
    var header: ?[]const u8 = null;
    var fn_a: ?[]const u8 = null;
    var fn_b: ?[]const u8 = null;
    while (r.peekSentinel('\n')) |line| {
        if (startsWith(u8, line, "diff --git a/")) if (header != null) break;
        defer len += line.len + 1;

        if (header == null and startsWith(u8, line, "--- ")) {
            if (startsWith(u8, line, "--- a/")) fn_a = line[6..];
            r.toss(line.len + 1);
            continue;
        }
        if (header == null and startsWith(u8, line, "+++ ")) {
            if (startsWith(u8, line, "+++ b/")) fn_b = line[6..];
            r.toss(line.len + 1);
            continue;
        }
        if (line.len > 0) switch (line[0]) {
            '@' => if (header == null) {
                header = blob[0..len];
            },
            '+' => add += 1,
            '-' => del += 1,
            else => {},
        };
        r.toss(line.len + 1);
    } else |e| switch (e) {
        error.EndOfStream => {},
        else => unreachable,
    }

    return .{
        .header = .{ .bytes = header orelse return error.MalformedDiff },
        .filename_a = fn_a,
        .filename_b = fn_b,
        .stat = .{
            .additions = add,
            .deletions = del,
            .total = @as(isize, add) - @as(isize, del),
        },
        .bytes = blob[0..len],
    };
}

pub fn blocksAlloc(diff: *const Diff, a: Allocator) ![]const []const u8 {
    const cnt = count(u8, diff.bytes, "\n@@");
    const blocks = try a.alloc([]const u8, cnt);
    errdefer a.free(blocks);
    const body = diff.bytes;
    var start: usize = findPos(u8, body, 0, "\n@@") orelse return error.MalformedBlock;
    for (blocks, 0..) |*block, i| {
        const end = findPos(u8, body, start + 1, "\n@@") orelse
            if (i == cnt) body.len else return error.MalformedBlock;
        block.* = body[start + 1 .. end];
        start = end;
    }

    return blocks;
}

test init {
    const blob =
        \\diff --git a/src/types/Viewers.zig b/src/types/Viewers.zig
        \\index 79832d5..e0d161d 100644
        \\--- a/src/types/Viewers.zig
        \\+++ b/src/types/Viewers.zig
        \\@@ -1,17 +1,15 @@
        \\-src: Types.DefaultHash,
        \\-time: i64,
        \\+src: Hash,
        \\+time: i64 = 0,
        \\ count: usize = 0,
        \\-
        \\-viewers: ArrayList(View),
        \\+viewers: ArrayList(View) = .empty,
        \\
        \\ const Viewers = @This();
        \\
        \\-pub const empty: Viewers = .{
        \\-    .src = @splat(0),
        \\-    .time = 0,
        \\-    .count = 0,
        \\-    .viewers = .empty,
        \\-};
        \\+pub const empty: Viewers = .{ .src = @splat(0) };
        \\+pub const type_prefix = .viewers;
        \\+pub const type_version: usize = 0;
        \\+pub const TypeIo = types.TypedIo(Viewers);
        \\+pub const Hash = types.DefaultHash;
        \\
        \\ pub const View = struct {
        \\     name: []const u8,
        \\@@ -36,36 +34,12 @@ pub const View = struct {
        \\     }
        \\ };
        \\
        \\-pub const type_prefix = .viewers;
        \\-pub const type_version: usize = 0;
        \\+pub fn new(T: type, src: *const T, io: Io) !Viewers {
        \\+    var viewers: Viewers = .empty;
        \\
        \\-const typeio = Types.readerWriter(Viewers, .empty);
        \\-const writerFn = typeio.write;
        \\-const readerFn = typeio.read;
        \\-const Index = Types.Index(type_prefix);
        \\-
        \\-pub fn new(src: Types.DefaultHash, viewer: []const u8, a: Allocator, io: Io) !Viewers {
        \\-    const views = try a.dupe(View, &.{
        \\-        .{ .name = viewer, .time = Io.Clock.real.now(io).toSeconds() },
        \\-    });
        \\-    var v: Viewers = .{
        \\-        .src = src,
        \\-        .time = views[0].time,
        \\-        .viewers = .{
        \\-            .items = views,
        \\-            .capacity = 1,
        \\-            .pointer_stability = .{},
        \\-        },
        \\-    };
        \\-
        \\-    try v.commit(io);
        \\-    return v;
        \\-}
        \\-
        \\-pub fn newFrom(T: type, src: *const T, viewer: []const u8, a: Allocator, io: Io) !Viewers {
        \\     switch (T) {
        \\-        Types.Delta => {
        \\-            var h = Types.DefaultHasher.init(.{});
        \\+        types.Delta => {
        \\+            var h = types.DefaultHasher.init(.{});
        \\             h.update(asBytes(&src.index));
        \\             h.update(asBytes(&src.created));
        \\             // may change
        \\@@ -73,46 +47,43 @@ pub fn newFrom(T: type, src: *const T, viewer: []const u8, a: Allocator, io: Io)
        \\             h.update(src.title);
        \\             h.update(src.author orelse "");
        \\             h.update(src.message);
        \\-            var hash: Types.DefaultHash = undefined;
        \\-            h.final(&hash);
        \\-            return .new(hash, viewer, a, io);
        \\+            h.final(&viewers.src);
        \\         },
        \\+        void => viewers.src = @splat('T'),
        \\         else => @compileError(@typeName(T) ++ " isn't implemented for Viewers.newFrom()"),
        \\     }
        \\+
        \\+    try viewers.commitNow(io);
        \\+    return viewers;
        \\ }
        \\
        \\-/// Experimental API
        \\-pub fn promoteFrom(v: *Viewers, T: type, a: Allocator, io: Io) !void {
        \\-    var parent: *T = @fieldParentPtr("viewers", v);
        \\+pub fn load(v: *Viewers, a: Allocator, io: Io) !void {
        \\+    var reader = try TypeIo.loadData(v, a, io);
        \\+    defer reader.file.close(io);
        \\+    TypeIo.read(v, &reader.interface);
        \\
        \\-    parent.viewers = try newFrom(T, parent, "", a, io);
        \\-}
        \\-
        \\-pub fn open(src: Types.DefaultHash, a: Allocator, io: Io) !Viewers {
        \\-    var reader = try Types.loadDataHashId(type_prefix, src, a, io);
        \\-    var v: Viewers = readerFn(&reader);
        \\-
        \\-    while (reader.takeSentinel('\n')) |line| {
        \\+    while (reader.interface.takeSentinel('\n')) |line| {
        \\         try v.viewers.append(a, View.parse(line) catch {
        \\-            log.err("line parse error in {x}", .{src});
        \\+            log.err("line parse error in {x}", .{v.src});
        \\             continue;
        \\         });
        \\     } else |err| switch (err) {
        \\-        error.EndOfStream => return v,
        \\+        error.EndOfStream => return,
        \\         error.ReadFailed => unreachable, // TODO validate{},
        \\         error.StreamTooLong => unreachable, // TODO validate
        \\     }
        \\-    return v;
        \\ }
        \\
        \\-pub fn commit(v: Viewers, io: Io) !void {
        \\-    if (v.count == 0) return;
        \\+pub fn commit(v: *const Viewers, io: Io) !void {
        \\+    if (v.count == 0 or v.viewers.items.len == 0) return;
        \\+    try v.commitNow(io);
        \\+}
        \\
        \\-    const file = try Types.commitHashId(type_prefix, v.src, io);
        \\-    defer file.close(io);
        \\+fn commitNow(v: *const Viewers, io: Io) !void {
        \\+    var writer = try TypeIo.commitExtra(v, io);
        \\+    defer writer.file.close(io);
        \\     var w_b: [2048]u8 = undefined;
        \\-    var writer = file.writer(io, &w_b);
        \\-    try writerFn(&v, &writer.interface);
        \\+    writer.interface.buffer = &w_b;
        \\
        \\     for (v.viewers.items) |viewer| {
        \\         try writer.interface.print("{}:{s}\n", .{ viewer.time, viewer.name });
        \\@@ -120,18 +91,9 @@ pub fn commit(v: Viewers, io: Io) !void {
        \\     try writer.interface.flush();
        \\ }
        \\
        \\-pub fn inc(v: *Viewers, io: Io) void {
        \\-    v.count +|= 1;
        \\-    v.time = Io.Clock.real.now(io).toSeconds();
        \\-    v.commit(io) catch |err| {
        \\-        log.err("unable to commit viewers {} {any}", .{ err, v.src });
        \\-    };
        \\-}
        \\-
        \\ pub fn view(v: *Viewers, name: []const u8, a: Allocator, io: Io) !void {
        \\     if (v.viewers.items.len == 0) {
        \\-        const copy = try open(v.src, a, io);
        \\-        v.viewers = copy.viewers;
        \\+        try v.load(a, io);
        \\     }
        \\
        \\     v.count +|= 1;
        \\@@ -141,19 +103,12 @@ pub fn view(v: *Viewers, name: []const u8, a: Allocator, io: Io) !void {
        \\     try v.commit(io);
        \\ }
        \\
        \\-pub fn liveCount(v: *const Viewers, io: Io) usize {
        \\-    if (v.time == 0) return v.count;
        \\-    var b: [1024]u8 = undefined;
        \\-    var fba: std.heap.FixedBufferAllocator = .init(&b);
        \\-    var reader = Types.loadDataHashId(type_prefix, v.src, fba.allocator(), io) catch |err| {
        \\-        log.err("unable to update viewer count {x} {}", .{ v.src, err });
        \\-        return v.count;
        \\-    };
        \\-    return readerFn(&reader).count;
        \\+pub fn typeIdent(v: Viewers, w: *Io.Writer) !void {
        \\+    try w.print("{x}", .{v.src});
        \\ }
        \\
        \\ pub fn format(v: *const Viewers, w: *Io.Writer) !void {
        \\-    try w.print("hash={x} count={} time={}", .{ v.src, v.count, v.time });
        \\+    try w.print("hash={x} count={d} time={d}", .{ v.src, v.count, v.time });
        \\ }
        \\
        \\ test format {
        \\@@ -163,7 +118,6 @@ test format {
        \\         .src = @splat('B'),
        \\         .count = 7,
        \\         .time = 69420,
        \\-        .viewers = .empty,
        \\     }, &w);
        \\
        \\     const text = "hash=4242424242424242424242424242424242424242424242424242424242424242 count=7 time=69420";
        \\@@ -174,7 +128,7 @@ pub fn fromLine(line: [:'\n']const u8) !Viewers {
        \\     var r: Io.Reader = .fixed(line);
        \\     var next = try r.takeDelimiter(' ') orelse return error.InvalidLine;
        \\     var hash: []const u8 = &.{};
        \\-    if (std.mem.cutPrefix(u8, next, "hash=")) |h| {
        \\+    if (cutPrefix(u8, next, "hash=")) |h| {
        \\         hash = h;
        \\     } else return error.InvalidLine;
        \\     var src: [32]u8 = @splat(0);
        \\@@ -188,13 +142,13 @@ pub fn fromLine(line: [:'\n']const u8) !Viewers {
        \\
        \\     var count: []const u8 = &.{};
        \\     next = try r.takeDelimiter(' ') orelse return error.InvalidLine;
        \\-    if (std.mem.cutPrefix(u8, next, "count=")) |c| {
        \\+    if (cutPrefix(u8, next, "count=")) |c| {
        \\         count = c;
        \\     } else return error.InvalidLine;
        \\
        \\     var time: []const u8 = &.{};
        \\     next = try r.takeDelimiter(' ') orelse return error.InvalidLine;
        \\-    if (std.mem.cutPrefix(u8, next, "time=")) |t| {
        \\+    if (cutPrefix(u8, next, "time=")) |t| {
        \\         time = t;
        \\     } else return error.InvalidLine;
        \\
        \\@@ -213,31 +167,39 @@ test fromLine {
        \\         .src = @splat('B'),
        \\         .count = 7,
        \\         .time = 69420,
        \\-        .viewers = .empty,
        \\     }, v);
        \\ }
        \\
        \\ test Viewers {
        \\-    const a = std.testing.allocator;
        \\+    const test_a = std.testing.allocator;
        \\     const io = std.testing.io;
        \\     var tempdir = std.testing.tmpDir(.{});
        \\     defer tempdir.cleanup();
        \\-    try Types.init(
        \\+    try types.init(
        \\         (try tempdir.dir.createDirPathOpen(io, @tagName(type_prefix), .{ .open_options = .{ .iterate = true } })),
        \\         io,
        \\     );
        \\
        \\     const mask: i64 = ~@as(i64, 0x7ffffff);
        \\+    var arena: std.heap.ArenaAllocator = .init(test_a);
        \\+    defer arena.deinit();
        \\+    const a = arena.allocator();
        \\+
        \\     const real = Io.Clock.real.now(io).toSeconds();
        \\     const now = real & mask;
        \\-    var viewers = try Viewers.new(@splat('v'), "grayhatter", a, io);
        \\+
        \\+    var viewers: Viewers = try .new(void, &{}, io);
        \\     defer viewers.viewers.deinit(a);
        \\+    viewers.time = now;
        \\+
        \\+    try viewers.view("grayhatter", a, io);
        \\+
        \\     viewers.time = now;
        \\     viewers.viewers.items[0].time = now;
        \\
        \\     var writer = std.Io.Writer.Allocating.init(a);
        \\     defer writer.deinit();
        \\-    try writerFn(&viewers, &writer.writer);
        \\+    try TypeIo.write(&viewers, &writer.writer);
        \\
        \\     for (viewers.viewers.items) |viewer|
        \\         try writer.writer.print("{}:{s}\n", .{ viewer.time, viewer.name });
        \\@@ -245,9 +207,9 @@ test Viewers {
        \\
        \\     const v1_text: []const u8 =
        \\         \\# viewers/0
        \\-        \\src: 7676767676767676767676767676767676767676767676767676767676767676
        \\+        \\src: 5454545454545454545454545454545454545454545454545454545454545454
        \\         \\time: 1744830464
        \\-        \\count: 0
        \\+        \\count: 1
        \\         \\
        \\         \\1744830464:grayhatter
        \\         \\
        \\@@ -256,7 +218,8 @@ test Viewers {
        \\     try std.testing.expectEqualStrings(v1_text, writer.written());
        \\
        \\     var r: Io.Reader = .fixed(writer.written());
        \\-    const read = readerFn(&r);
        \\+    var read: Viewers = .empty;
        \\+    TypeIo.read(&read, &r);
        \\     try std.testing.expectEqual(viewers.src, read.src);
        \\ }
        \\
        \\@@ -268,5 +231,5 @@ const Io = std.Io;
        \\ const findScalar = std.mem.findScalar;
        \\ const parseInt = std.fmt.parseInt;
        \\ const asBytes = std.mem.asBytes;
        \\-
        \\-const Types = @import("../types.zig");
        \\+const cutPrefix = std.mem.cutPrefix;
        \\+const types = @import("../types.zig");
        \\
    ;
    var r: Reader = .fixed(blob);
    const diff = try init(&r);

    try std.testing.expectEqualDeep(Diff{
        .bytes = blob,
        .header = .{ .bytes = blob[0..145] },
        .filename_a = "src/types/Viewers.zig",
        .filename_b = "src/types/Viewers.zig",
        .stat = .{ .additions = 58, .deletions = 95, .total = -37 },
    }, diff);
}

test "deleted file" {
    const blob =
        \\diff --git a/src/types/Issue.zig b/src/types/Issue.zig
        \\deleted file mode 100644
        \\index f14ee40..0000000
        \\--- a/src/types/Issue.zig
        \\+++ /dev/null
        \\@@ -1,116 +0,0 @@
        \\-index: usize,
        \\-status: Status = .open,
        \\-created: i64 = 0,
        \\-updated: i64 = 0,
        \\-repo: []const u8,
        \\-title: []const u8,
        \\-desc: []const u8,
        \\-
        \\-comment_data: ?[]const u8 = null,
        \\-
        \\-const Issue = @This();
        \\-
        \\-pub const type_prefix = .issues;
        \\-pub const type_version: usize = 0;
        \\-
        \\-const ISSUE_VERSION: usize = 0;
        \\-
        \\-pub const Status = enum(u1) {
        \\-    open = 0,
        \\-    closed = 1,
        \\-};
        \\-
        \\-const typeio = Types.readerWriter(Issue, .{ .index = 0, .repo = &.{}, .title = &.{}, .desc = &.{} });
        \\-const writerFn = typeio.write;
        \\-const readerFn = typeio.read;
        \\-const Index = Types.Index(type_prefix);
        \\-
        \\-pub fn new(repo: []const u8, title: []const u8, desc: []const u8) !Issue {
        \\-    const max: usize = try Index.next();
        \\-    const d = Issue{
        \\-        .index = max + 1,
        \\-        .state = 0,
        \\-        .repo = repo,
        \\-        .title = title,
        \\-        .desc = desc,
        \\-        .comment_data = null,
        \\-    };
        \\-    try d.commit();
        \\-
        \\-    return d;
        \\-}
        \\-
        \\-pub fn open(a: std.mem.Allocator, index: usize) !?Issue {
        \\-    const max = try Index.current();
        \\-    if (index > max) return error.IssueDoesNotExist;
        \\-
        \\-    var buf: [2048]u8 = undefined;
        \\-    const filename = try std.fmt.bufPrint(&buf, "{x}.issue", .{index});
        \\-    var reader = try Types.loadDataReader(.issue, a, filename);
        \\-    return readerFn(&reader);
        \\-}
        \\-
        \\-pub fn commit(issue: Issue) !void {
        \\-    if (issue.messages) |msgs| {
        \\-        // Make a best effort to save/protect all data
        \\-        for (msgs) |msg| msg.commit() catch continue;
        \\-    }
        \\-
        \\-    var buf: [2048]u8 = undefined;
        \\-    const filename = try std.fmt.bufPrint(&buf, "{x}.issue", .{issue.index});
        \\-    const file = try Types.commit(.thread, filename);
        \\-    defer file.close();
        \\-    var writer = file.writer();
        \\-    try writerFn(&issue, &writer);
        \\-}
        \\-
        \\-test "reader/writer" {
        \\-    const a = std.testing.allocator;
        \\-    var writer = std.Io.Writer.Allocating.init(a);
        \\-    defer writer.deinit();
        \\-
        \\-    const this: Issue = .{
        \\-        .index = 55,
        \\-        .status = .open,
        \\-        .created = 0,
        \\-        .updated = 0,
        \\-        .repo = "srctree",
        \\-        .title = "title",
        \\-        .desc = "desc",
        \\-        .comment_data = null,
        \\-    };
        \\-    try writerFn(&this, &writer.writer);
        \\-
        \\-    const expected =
        \\-        \\# issues/0
        \\-        \\index: 55
        \\-        \\status: open
        \\-        \\created: 0
        \\-        \\updated: 0
        \\-        \\repo: srctree
        \\-        \\title: title
        \\-        \\desc: desc
        \\-        \\
        \\-        \\
        \\-    ;
        \\-    const expected_var = try a.dupe(u8, expected);
        \\-    defer a.free(expected_var);
        \\-
        \\-    try std.testing.expectEqualStrings(expected, writer.written());
        \\-
        \\-    {
        \\-        var reader: std.Io.Reader = .fixed(writer.written());
        \\-        const read_this = readerFn(&reader);
        \\-        try std.testing.expectEqualDeep(this, read_this);
        \\-    }
        \\-
        \\-    {
        \\-        var reader: std.Io.Reader = .fixed(expected_var);
        \\-        const from_expected_this = readerFn(&reader);
        \\-        try std.testing.expectEqualDeep(this, from_expected_this);
        \\-    }
        \\-}
        \\-
        \\-const std = @import("std");
        \\-const Allocator = std.mem.Allocator;
        \\-const Types = @import("../types.zig");
        \\
    ;

    var r: Reader = .fixed(blob);
    const diff = try init(&r);

    try std.testing.expectEqualDeep(Diff{
        .bytes = blob,
        .header = .{ .bytes = blob[0..143] },
        .filename_a = "src/types/Issue.zig",
        .filename_b = null,
        .stat = .{ .additions = 0, .deletions = 116, .total = -116 },
    }, diff);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const count = std.mem.count;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const assert = std.debug.assert;
const eql = std.mem.eql;
const find = std.mem.find;
const findPos = std.mem.findPos;
const log = std.log.scoped(.git_patch);
const verse = @import("verse");
const abx = verse.Antibiotic;
