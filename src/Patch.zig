blob: []const u8,
diffs: ?[]Diff = null,
/// srctree metadata
revision: ?u64 = null,

const Patch = @This();

pub const Diff = @import("Patch/Diff.zig");
pub const Formatted = union(Formatted.Flavor) {
    inlined: Inlined,
    split: Split,

    pub const Flavor = enum {
        inlined,
        split,
    };

    pub fn format(fmt: Formatted, w: *Io.Writer) !void {
        return switch (fmt) {
            .inlined => |in| in.format(w),
            .split => |sp| sp.format(w),
        };
    }
};

pub const Inlined = struct {
    lang: syntax.Language,
    file_idx: u16,
    lines: []Diff.Line,

    pub fn fromParsed(lines: []Diff.Line, file_idx: usize, name: []const u8) Inlined {
        return .{
            .file_idx = @intCast(file_idx),
            .lang = syntax.Language.guessFromName(name) orelse .txt,
            .lines = lines,
        };
    }

    fn fmtLine(line: Diff.Line, fnum: []const u8, w: *Io.Writer) !void {
        switch (line) {
            .hdr => |hdr| try w.print("<div class=\"block\">{f}</div>", .{hdr}),
            .ctx => |ctx| try w.print(
                \\<ln id="{3s}L{1d}" num="{0d}"><lnex num="{1d}">{2f}</lnex></ln>
            , .{ ctx.number, ctx.number_right, ctx, fnum }),
            .del => |del| try w.print(
                \\<ln id="{2s}LL{0d}" num="{0d}" class="del"><lnex class="del">{1f}</lnex></ln>
            , .{ del.number, del, fnum }),
            .add => |add| try w.print(
                \\<ln id="{2s}RL{0d}" class="add"><lnex num="{0d}" class="add">{1f}</lnex></ln>
            , .{ add.number_right, add, fnum }),
            .nul => unreachable,
        }
    }

    /// formatColor leaves lines in an undefined state
    pub fn formatColor(inl: Inlined, a: Allocator, w: *Io.Writer) !void {
        if (inl.lang != .zig) return inl.format(w);

        var fnum_b: [10]u8 = undefined;
        var fnum: []const u8 = &.{};
        if (inl.file_idx > 0)
            fnum = std.fmt.bufPrint(&fnum_b, "F{d}", .{inl.file_idx}) catch unreachable;

        var line_b: [0x200]u8 = undefined;
        var write_b: [0x200]u8 = undefined;

        for (inl.lines) |raw_line| {
            var line: Diff.Line = raw_line;
            var writer: Io.Writer = .fixed(&write_b);

            switch (line) {
                .hdr, .nul => try fmtLine(line, fnum, w),
                .ctx, .add, .del => |*raw| {
                    // use raw.text to cover writer.len
                    std.debug.assert(raw.text.len < line_b.len);
                    const text = std.mem.trimStart(u8, raw.text, " \t\n");
                    @memcpy(line_b[0..text.len], text);
                    line_b[text.len] = 0;
                    const input: [:0]u8 = line_b[0..text.len :0];
                    for (0..raw.text.len - text.len) |_| writer.writeByte(' ') catch unreachable;
                    syntax.zig.highlight(input, &writer, a) catch {
                        writer.writeAll(input) catch unreachable;
                    };
                    raw.text = writer.buffered();
                    raw.clean = true;
                    try fmtLine(line, fnum, w);
                },
            }
        }
    }

    pub fn format(inl: Inlined, w: *Io.Writer) !void {
        var fnum_b: [10]u8 = undefined;
        var fnum: []const u8 = &.{};
        if (inl.file_idx > 0)
            fnum = std.fmt.bufPrint(&fnum_b, "F{d}", .{inl.file_idx}) catch unreachable;

        for (inl.lines) |line|
            try fmtLine(line, fnum, w);
    }
};

pub const Split = struct {
    lang: syntax.Language,
    file_idx: u16,
    left: []Diff.Line,
    right: []Diff.Line,

    pub fn fromInlined(lines: []Diff.Line, file_idx: usize, name: []const u8, a: Allocator) !Split {
        var left: ArrayList(Diff.Line) = try .initCapacity(a, lines.len / 2);
        var right: ArrayList(Diff.Line) = try .initCapacity(a, lines.len / 2);
        for (lines) |line| {
            switch (line) {
                .hdr => {
                    try left.append(a, line);
                    try right.append(a, line);
                },
                .add => try right.append(a, line),
                .del => try left.append(a, line),
                .ctx => {
                    if (left.items.len > right.items.len) {
                        const rcount = left.items.len - right.items.len;
                        for (0..rcount) |_|
                            try right.append(a, .empty);
                    } else if (left.items.len < right.items.len) {
                        const lcount = right.items.len - left.items.len;
                        for (0..lcount) |_|
                            try left.append(a, .empty);
                    }
                    try left.append(a, line);
                    try right.append(a, line);
                },
                .nul => unreachable,
            }
        }

        return .{
            .file_idx = @intCast(file_idx),
            .lang = syntax.Language.guessFromName(name) orelse .txt,
            .left = try left.toOwnedSlice(a),
            .right = try right.toOwnedSlice(a),
        };
    }

    pub const Left = struct {
        fn fmtLine(line: Diff.Line, fnum: []const u8, w: *Io.Writer) !void {
            switch (line) {
                .hdr => |hdr| try w.print("<div class=\"block\">{f}</div>", .{hdr}),
                .add => unreachable,
                .del => |del| try w.print(
                    \\<ln num="{0d}" id="{2s}LL{0d}" class="del">{1f}</ln>
                , .{ del.number, del, fnum }),
                .ctx => |ctx| try w.print(
                    \\<ln num="{0d}" id="{2s}LL{0d}">{1f}</ln>
                , .{ ctx.number, ctx, fnum }),
                .nul => try w.print("<div class=\"nul\"></div>", .{}),
            }
        }

        /// formatColor leaves lines in an undefined state
        pub fn formatColor(split: Split, a: Allocator, w: *Io.Writer) !void {
            var fnum_b: [10]u8 = undefined;
            var fnum: []const u8 = &.{};
            if (split.file_idx > 0)
                fnum = std.fmt.bufPrint(&fnum_b, "F{d}", .{split.file_idx}) catch unreachable;

            var line_b: [0x200]u8 = undefined;
            var write_b: [0x200]u8 = undefined;

            for (split.left) |raw_line| {
                var line: Diff.Line = raw_line;
                var writer: Io.Writer = .fixed(&write_b);

                switch (line) {
                    .hdr, .nul => try fmtLine(line, fnum, w),
                    .ctx, .add, .del => |*raw| {
                        // use raw.text to cover writer.len
                        std.debug.assert(raw.text.len < line_b.len);
                        const text = std.mem.trimStart(u8, raw.text, " \t\n");
                        @memcpy(line_b[0..text.len], text);
                        line_b[text.len] = 0;
                        const input: [:0]u8 = line_b[0..text.len :0];
                        for (0..raw.text.len - text.len) |_| writer.writeByte(' ') catch unreachable;
                        syntax.zig.highlight(input, &writer, a) catch {
                            writer.writeAll(input) catch unreachable;
                        };
                        raw.text = writer.buffered();
                        raw.clean = true;
                        try fmtLine(line, fnum, w);
                    },
                }
            }
        }

        pub fn format(split: Split, w: *Io.Writer) !void {
            var fnum_b: [10]u8 = undefined;
            var fnum: []const u8 = &.{};
            if (split.file_idx > 0)
                fnum = std.fmt.bufPrint(&fnum_b, "F{d}", .{split.file_idx}) catch unreachable;

            for (split.left) |left|
                try fmtLine(left, fnum, w);
        }
    };

    pub const Right = struct {
        fn fmtLine(line: Diff.Line, fnum: []const u8, w: *Io.Writer) !void {
            switch (line) {
                .hdr => |hdr| try w.print("<div class=\"block\">{f}</div>", .{hdr}),
                .add => |add| try w.print(
                    \\<ln num="{0d}" id="{2s}RL{0d}" class="add">{1f}</ln>
                , .{ add.number, add, fnum }),
                .del => unreachable,
                .ctx => |ctx| try w.print(
                    \\<ln num="{0d}" id="{2s}RL{0d}">{1f}</ln>
                , .{ ctx.number_right, ctx, fnum }),
                .nul => try w.print("<div class=\"nul\"></div>", .{}),
            }
        }

        /// formatColor leaves lines in an undefined state
        pub fn formatColor(split: Split, a: Allocator, w: *Io.Writer) !void {
            var fnum_b: [10]u8 = undefined;
            var fnum: []const u8 = &.{};
            if (split.file_idx > 0)
                fnum = std.fmt.bufPrint(&fnum_b, "F{d}", .{split.file_idx}) catch unreachable;

            var line_b: [0x200]u8 = undefined;
            var write_b: [0x200]u8 = undefined;

            for (split.right) |raw_line| {
                var line: Diff.Line = raw_line;
                var writer: Io.Writer = .fixed(&write_b);

                switch (line) {
                    .hdr, .nul => try fmtLine(line, fnum, w),
                    .ctx, .add, .del => |*raw| {
                        // use raw.text to cover writer.len
                        std.debug.assert(raw.text.len < line_b.len);
                        const text = std.mem.trimStart(u8, raw.text, " \t\n");
                        @memcpy(line_b[0..text.len], text);
                        line_b[text.len] = 0;
                        const input: [:0]u8 = line_b[0..text.len :0];
                        for (0..raw.text.len - text.len) |_| writer.writeByte(' ') catch unreachable;
                        syntax.zig.highlight(input, &writer, a) catch {
                            writer.writeAll(input) catch unreachable;
                        };
                        raw.text = writer.buffered();
                        raw.clean = true;
                        try fmtLine(line, fnum, w);
                    },
                }
            }
        }

        pub fn format(split: Split, w: *Io.Writer) !void {
            var fnum_b: [10]u8 = undefined;
            var fnum: []const u8 = &.{};
            if (split.file_idx > 0)
                fnum = std.fmt.bufPrint(&fnum_b, "F{d}", .{split.file_idx}) catch unreachable;

            for (split.right) |right|
                try fmtLine(right, fnum, w);
        }
    };

    pub fn formatColor(split: Split, a: Allocator, left: *Io.Writer, right: *Io.Writer) !void {
        if (split.lang != .zig) {
            try Split.Left.format(split, left);
            try Split.Right.format(split, right);
            return;
        }

        try Split.Left.formatColor(split, a, left);
        try Split.Right.formatColor(split, a, right);
    }

    pub fn format(split: Split, left: *Io.Writer, right: *Io.Writer) !void {
        try Split.Left.format(split, left);
        try Split.Right.format(split, right);
    }
};

pub const Stat = struct {
    files: usize,
    additions: usize,
    deletions: usize,
    total: isize,
};

pub fn init(patch: []const u8) Patch {
    return .{ .blob = patch };
}

pub fn isValid(_: Patch) bool {
    return true; // lol, you thought this did something :D
}

pub const ParseError = error{
    OutOfMemory,
    Invalid,
    Empty,
};

pub fn parse(self: *Patch, a: Allocator) ParseError!void {
    if (self.diffs != null) return; // Assume successful parsing
    const diff_count = count(u8, self.blob, "\ndiff --git a/") +
        @as(usize, if (startsWith(u8, self.blob, "diff --git a/")) 1 else 0);

    if (diff_count == 0) return error.Empty;
    self.diffs = try a.alloc(Diff, diff_count);
    errdefer {
        a.free(self.diffs.?);
        self.diffs = null;
    }
    var start: usize = findPos(u8, self.blob, 0, "diff --git a/") orelse {
        return error.Invalid;
    };
    var end: usize = start;
    for (self.diffs.?) |*diff| {
        assert(self.blob[start] != '\n');
        end = if (findPos(u8, self.blob, start + 1, "\ndiff --git a/")) |s| s + 1 else self.blob.len;
        diff.* = try Diff.init(self.blob[start..end]);
        start = end;
    }
}

pub fn patchStat(p: Patch) Stat {
    const a = count(u8, p.blob, "\n+") - count(u8, p.blob, "\n+++ a/");
    const d = count(u8, p.blob, "\n-") - count(u8, p.blob, "\n--- b/");
    const files = count(u8, p.blob, "\ndiff --git a/") +
        @as(usize, if (startsWith(u8, p.blob, "diff --git a/")) 1 else 0);
    return .{
        .files = files,
        .additions = a,
        .deletions = d,
        .total = @intCast(a -| d),
    };
}

fn fetch(uri: []const u8, a: Allocator, io: Io) ![]u8 {
    var client = std.http.Client{ .allocator = a, .io = io };
    defer client.deinit();

    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(a);
    const request = client.fetch(.{ .location = .{ .url = uri } });
    if (request) |req| {
        log.err("request code {}\n", .{req.status});
        log.err("request body {s}\n", .{response.items});
        return try response.toOwnedSlice(a);
    } else |err| {
        log.err("stdlib request failed with error {}\n", .{err});
    }

    return error.EmptyReponse;
}

pub fn fromRemote(uri: []const u8, a: Allocator, io: Io) !Patch {
    return Patch{ .blob = try fetch(uri, a, io) };
}

fn lineNumberFromHeader(str: []const u8) !Diff.Line.Header {
    assert(startsWith(u8, str, "@@ -"));
    var idx: usize = 4;
    const left: u32 = if (findAnyPos(u8, str, idx, " ,")) |end|
        try parseInt(u32, str[idx..end], 10)
    else
        return error.InvalidHeader;

    idx = indexOfScalarPos(u8, str, idx, '+') orelse return error.InvalidHeader;
    const right: u32 = if (findAnyPos(u8, str, idx, " ,")) |end|
        try parseInt(u32, str[idx..end], 10)
    else
        return error.InvalidHeader;

    return .{ .left = left, .right = right, .text = str };
}

test lineNumberFromHeader {
    const hdr = try lineNumberFromHeader("@@ -11,6 +11,8 @@ pub const verse_routes = [_]Match{");
    try std.testing.expectEqual(@as(u32, 11), hdr.left);
    try std.testing.expectEqual(@as(u32, 11), hdr.right);
    const hdr1 = try lineNumberFromHeader("@@ -1 +1 @@");
    try std.testing.expectEqual(@as(u32, 1), hdr1.left);
    try std.testing.expectEqual(@as(u32, 1), hdr1.right);
    const hdr2 = try lineNumberFromHeader("@@ -1 +1,3 @@");
    try std.testing.expectEqual(@as(u32, 1), hdr2.left);
    try std.testing.expectEqual(@as(u32, 1), hdr2.right);
}

pub fn formatted(name: []const u8, diff: []const u8, file_idx: usize, flavor: Formatted.Flavor, a: Allocator) !Formatted {
    const line_count = std.mem.count(u8, diff, "\n");
    var lines: ArrayList(Diff.Line) = .empty;
    var litr = splitScalar(u8, diff, '\n');
    var hdr: Diff.Line.Header = .{ .left = 0, .right = 0 };
    var linenum_l: u32 = 0;
    var linenum_r: u32 = 0;
    for (0..line_count + 1) |_| {
        const line = litr.next().?;
        const text: []const u8 = if (line.len > 0) if (line[0] != '@') line[1..] else line else "&nbsp;";
        if (line.len > 0) switch (line[0]) {
            '@' => {
                hdr = lineNumberFromHeader(line) catch {
                    log.err("{s}", .{diff});
                    unreachable;
                };
                linenum_l, linenum_r = hdr.split();
                try lines.append(a, .{ .hdr = hdr });
            },
            '-' => {
                try lines.append(a, .{ .del = .{ .text = text, .number = linenum_l } });
                linenum_l += 1;
            },
            '+' => {
                try lines.append(a, .{ .add = .{ .text = text, .number = linenum_r, .number_right = linenum_r } });
                linenum_r += 1;
            },
            ' ' => {
                try lines.append(a, .{ .ctx = .{ .text = text, .number = linenum_l, .number_right = linenum_r } });
                linenum_l += 1;
                linenum_r += 1;
            },
            else => break,
        };
    }
    const diff_lines = try lines.toOwnedSlice(a);

    switch (flavor) {
        .inlined => return .{
            .inlined = .fromParsed(diff_lines, file_idx, name),
        },
        .split => return .{
            .split = try .fromInlined(diff_lines, file_idx, name, a),
        },
    }
}

test "simple rename" {
    var a = std.testing.allocator;
    const rn_patch =
        \\diff --git a/src/zir_sema.zig b/src/Sema.zig
        \\similarity index 100%
        \\rename from src/zir_sema.zig
        \\rename to src/Sema.zig
        \\
    ;
    var patch = Patch.init(rn_patch);
    try patch.parse(a);
    const diffs: []Diff = patch.diffs.?;
    defer a.free(diffs);
    try std.testing.expectEqual(1, diffs.len);
}

test "diffsSlice" {
    var a = std.testing.allocator;

    const s_patch =
        \\diff --git a/src/fs.zig b/src/fs.zig
        \\index 948efff..ddac25e 100644
        \\--- a/src/fs.zig
        \\+++ b/src/fs.zig
        \\@@ -86,6 +86,7 @@ pub fn init(a: mem.Allocator, env: std.process.EnvMap) !fs {
        \\     var self = fs{
        \\         .alloc = a,
        \\         .rc = findCoreFile(a, &env, .rc),
        \\+        .history = findCoreFile(a, &env, .history),
        \\         .dirs = .{
        \\             .cwd = try std.fs.cwd().openIterableDir(".", .{}),
        \\         },
        \\diff --git a/build.zig b/build.zig
        \\index d5c30e1..bbf3794 100644
        \\--- a/build.zig
        \\+++ b/build.zig
        \\@@ -13,6 +13,7 @@ pub fn build(b: *std.Build) void {
        \\     });
        \\
        \\     exe.linkSystemLibrary2("curl", .{ .preferred_link_mode = .Static });
        \\+    exe.linkLibC();
        \\
        \\     addSrcTemplates(exe);
        \\     b.installArtifact(exe);
        \\
    ;
    const a_patch = try a.dupe(u8, s_patch);
    defer a.free(a_patch);
    var p = Patch{
        .blob = a_patch,
    };
    try p.parse(a);
    const diffs = p.diffs.?;
    defer a.free(diffs);
    try std.testing.expect(diffs.len == 2);
    const h = diffs[1];
    try std.testing.expectEqualStrings(h.filename.?, "build.zig");
}

const std = @import("std");
const syntax = @import("syntax.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Reader = Io.Reader;
const count = std.mem.count;
const startsWith = std.mem.startsWith;
const assert = std.debug.assert;
const findPos = std.mem.findPos;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const findAnyPos = std.mem.findAnyPos;
const splitScalar = std.mem.splitScalar;
const parseInt = std.fmt.parseInt;
const log = std.log.scoped(.git_patch);
