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
    lang: highlight.Language,
    file_idx: u16,
    lines: []Diff.Line,

    pub fn fromParsed(lines: []Diff.Line, file_idx: usize) Inlined {
        return .{
            .file_idx = @intCast(file_idx),
            .lang = .txt,
            .lines = lines,
        };
    }

    pub fn format(inl: Inlined, w: *Io.Writer) !void {
        var fnum_b: [10]u8 = undefined;
        var fnum: []const u8 = &.{};
        if (inl.file_idx > 0) fnum = std.fmt.bufPrint(&fnum_b, "F{d}", .{inl.file_idx}) catch unreachable;
        for (inl.lines) |line| switch (line) {
            .hdr => |hdr| try w.print("<div class=\"block\">{s}</div>", .{hdr.text}),
            .ctx => |ctx| try w.print(
                \\<ln id="{3s}L{1d}" num="{0d}"><lnex num="{1d}">{2s}</lnex></ln>
            , .{ ctx.number, ctx.number_right, ctx.text, fnum }),
            .del => |del| try w.print(
                \\<ln id="{2s}LL{0d}" num="{0d}" class="del"><lnex class="del">{1s}</lnex></ln>
            , .{ del.number, del.text, fnum }),
            .add => |add| try w.print(
                \\<ln id="{2s}RL{0d}" class="add"><lnex num="{0d}" class="add">{1s}</lnex></ln>
            , .{ add.number_right, add.text, fnum }),
            .nul => unreachable,
        };
    }
};

pub const Split = struct {
    lang: highlight.Language,
    file_idx: u16,
    left: []Diff.Line,
    right: []Diff.Line,

    pub fn fromInlined(lines: []Diff.Line, file_idx: usize, a: Allocator) !Split {
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
            .lang = .txt,
            .left = try left.toOwnedSlice(a),
            .right = try right.toOwnedSlice(a),
        };
    }

    pub fn fmtLeft(split: Split, w: *Io.Writer) !void {
        var fnum_b: [10]u8 = undefined;
        var fnum: []const u8 = &.{};
        if (split.file_idx > 0) fnum = std.fmt.bufPrint(&fnum_b, "F{d}", .{split.file_idx}) catch unreachable;

        for (split.left) |left| switch (left) {
            .hdr => |hdr| try w.print("<div class=\"block\">{s}</div>", .{hdr.text}),
            .add => unreachable,
            .del => |del| try w.print(
                \\<ln num="{0d}" id="{2s}LL{0d}" class="del">{1s}</ln>
            , .{ del.number, del.text, fnum }),
            .ctx => |ctx| try w.print(
                \\<ln num="{0d}" id="{2s}LL{0d}">{1s}</ln>
            , .{ ctx.number, ctx.text, fnum }),
            .nul => try w.print("<div class=\"nul\"></div>", .{}),
        };
    }

    pub fn fmtRight(split: Split, w: *Io.Writer) !void {
        var fnum_b: [10]u8 = undefined;
        var fnum: []const u8 = &.{};
        if (split.file_idx > 0) fnum = std.fmt.bufPrint(&fnum_b, "F{d}", .{split.file_idx}) catch unreachable;

        for (split.right) |right| switch (right) {
            .hdr => |hdr| try w.print("<div class=\"block\">{s}</div>", .{hdr.text}),
            .add => |add| try w.print(
                \\<ln num="{0d}" id="{2s}RL{0d}" class="add">{1s}</ln>
            , .{ add.number, add.text, fnum }),
            .del => unreachable,
            .ctx => |ctx| try w.print(
                \\<ln num="{0d}" id="{2s}RL{0d}">{1s}</ln>
            , .{ ctx.number_right, ctx.text, fnum }),
            .nul => try w.print("<div class=\"nul\"></div>", .{}),
        };
    }

    pub fn format(split: Split, w: *Io.Writer) !void {
        try split.fmtLeft(w);
        try split.fmtRight(w);
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

pub fn formatted(a: Allocator, diff: []const u8, file_idx: usize, flavor: Formatted.Flavor) !Formatted {
    const clean = a.print("{f}", .{abx.Html{ .text = diff }}) catch unreachable;
    const line_count = std.mem.count(u8, clean, "\n");
    var lines: ArrayList(Diff.Line) = .empty;
    var litr = splitScalar(u8, clean, '\n');
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
            .inlined = .fromParsed(diff_lines, file_idx),
        },
        .split => return .{
            .split = try .fromInlined(diff_lines, file_idx, a),
        },
    }
}

pub fn diffLineHtmlUnified(a: Allocator, diff: []const u8) ![]Diff.Line {
    const clean = a.print("{f}", .{abx.Html{ .text = diff }}) catch unreachable;
    const line_count = std.mem.count(u8, clean, "\n");
    var lines: ArrayList(Diff.Line) = .empty;
    var litr = splitScalar(u8, clean, '\n');
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
    return try lines.toOwnedSlice(a);
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
const highlight = @import("syntax-highlight.zig");
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

const verse = @import("verse");
const abx = verse.Antibiotic;
