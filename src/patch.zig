blob: []const u8,
diffs: ?[]Diff = null,

const Patch = @This();

pub const Diff = @import("patch/Diff.zig");

pub const Split = struct {
    left: []Diff.Line,
    right: []Diff.Line,
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

pub fn parse(self: *Patch, a: Allocator) !void {
    if (self.diffs != null) return; // Assume successful parsing
    const diff_count = count(u8, self.blob, "\ndiff --git a/") +
        @as(usize, if (startsWith(u8, self.blob, "diff --git a/")) 1 else 0);
    if (diff_count == 0) return error.PatchInvalid;
    self.diffs = try a.alloc(Diff, diff_count);
    errdefer {
        a.free(self.diffs.?);
        self.diffs = null;
    }
    var start: usize = indexOfPos(u8, self.blob, 0, "diff --git a/") orelse {
        return error.PatchInvalid;
    };
    var end: usize = start;
    for (self.diffs.?) |*diff| {
        assert(self.blob[start] != '\n');
        end = if (indexOfPos(u8, self.blob, start + 1, "\ndiff --git a/")) |s| s + 1 else self.blob.len;
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
    //defer client.deinit();

    var response: std.ArrayList(u8) = .{};
    defer response.deinit(a);
    const request = client.fetch(.{
        .location = .{ .url = uri },
        //.response_storage = .{ .dynamic = &response },
        //.max_append_size = 0xffffff,
    });
    if (request) |req| {
        log.err("request code {}\n", .{req.status});
        log.err("request body {s}\n", .{response.items});
        return try response.toOwnedSlice(a);
    } else |err| {
        log.err("stdlib request failed with error {}\n", .{err});
    }

    const curl = try CURL.curlRequest(a, uri);
    if (curl.code != 200) return error.UnexpectedResponseCode;

    if (curl.body) |b| return b;
    return error.EpmtyReponse;
}

pub fn fromRemote(uri: []const u8, a: Allocator, io: Io) !Patch {
    return Patch{
        .blob = try fetch(uri, a, io),
    };
}

fn lineNumberFromHeader(str: []const u8) !struct { u32, u32 } {
    assert(startsWith(u8, str, "@@ -"));
    var idx: usize = 4;
    const left: u32 = if (indexOfAnyPos(u8, str, idx, " ,")) |end|
        try parseInt(u32, str[idx..end], 10)
    else
        return error.InvalidHeader;

    idx = indexOfScalarPos(u8, str, idx, '+') orelse return error.InvalidHeader;
    const right: u32 = if (indexOfAnyPos(u8, str, idx, " ,")) |end|
        try parseInt(u32, str[idx..end], 10)
    else
        return error.InvalidHeader;
    return .{ left, right };
}

test lineNumberFromHeader {
    const l, const r = try lineNumberFromHeader("@@ -11,6 +11,8 @@ pub const verse_routes = [_]Match{");
    try std.testing.expectEqual(@as(u32, 11), l);
    try std.testing.expectEqual(@as(u32, 11), r);
    const l1, const r1 = try lineNumberFromHeader("@@ -1 +1 @@");
    try std.testing.expectEqual(@as(u32, 1), l1);
    try std.testing.expectEqual(@as(u32, 1), r1);
    const l2, const r2 = try lineNumberFromHeader("@@ -1 +1,3 @@");
    try std.testing.expectEqual(@as(u32, 1), l2);
    try std.testing.expectEqual(@as(u32, 1), r2);
}

pub fn diffLineHtmlSplit(a: Allocator, diff: []const u8) !Split {
    const clean = allocPrint(a, "{f}", .{abx.Html{ .text = diff }}) catch unreachable;
    const line_count = std.mem.count(u8, clean, "\n");
    var litr = std.mem.splitScalar(u8, clean, '\n');

    var left: ArrayList(Diff.Line) = .{};
    var right: ArrayList(Diff.Line) = .{};
    var linenum_l: u32 = 0;
    var linenum_r: u32 = 0;
    for (0..line_count + 1) |_| {
        const line = litr.next().?;
        if (line.len > 0) {
            const spaced = if (line.len == 1) "&nbsp;" else line[1..];
            switch (line[0]) {
                '-' => {
                    try left.append(a, .{ .del = .{ .text = spaced, .number = linenum_l } });
                    linenum_l += 1;
                },
                '+' => {
                    try right.append(a, .{ .add = .{ .text = spaced, .number = linenum_r } });
                    linenum_r += 1;
                },
                '@' => {
                    linenum_l, linenum_r = try lineNumberFromHeader(line);
                    try left.append(a, .{ .hdr = line });
                    try right.append(a, .{ .hdr = line });
                },
                else => {
                    if (left.items.len > right.items.len) {
                        const rcount = left.items.len - right.items.len;
                        for (0..rcount) |_|
                            try right.append(a, .empty);
                    } else if (left.items.len < right.items.len) {
                        const lcount = right.items.len - left.items.len;
                        for (0..lcount) |_|
                            try left.append(a, .empty);
                    }
                    try left.append(a, .{ .ctx = .{ .text = spaced, .number = linenum_l } });
                    linenum_l += 1;
                    try right.append(a, .{ .ctx = .{ .text = spaced, .number = linenum_r } });
                    linenum_r += 1;
                },
            }
        }
    }

    return .{ .left = try left.toOwnedSlice(a), .right = try right.toOwnedSlice(a) };
}

pub fn diffLineHtmlUnified(a: Allocator, diff: []const u8) ![]Diff.Line {
    const clean = allocPrint(a, "{f}", .{abx.Html{ .text = diff }}) catch unreachable;
    const line_count = std.mem.count(u8, clean, "\n");
    var lines: ArrayList(Diff.Line) = .{};
    var litr = splitScalar(u8, clean, '\n');
    var linenum_l: u32 = 0;
    var linenum_r: u32 = 0;
    for (0..line_count + 1) |_| {
        const line = litr.next().?;
        const text: []const u8 = if (line.len > 0) if (line[0] != '@') line[1..] else line else "&nbsp;";
        if (line.len > 0) switch (line[0]) {
            '@' => {
                linenum_l, linenum_r = lineNumberFromHeader(line) catch {
                    log.err("{s}", .{diff});
                    unreachable;
                };
                try lines.append(a, .{ .hdr = text });
            },
            '-' => {
                try lines.append(a, .{ .del = .{ .text = text, .number = linenum_l } });
                linenum_l += 1;
            },
            '+' => {
                try lines.append(a, .{ .add = .{ .text = text, .number = 0, .number_right = linenum_r } });
                linenum_r += 1;
            },
            else => {
                try lines.append(a, .{ .ctx = .{ .text = text, .number = linenum_l, .number_right = linenum_r } });
                linenum_l += 1;
                linenum_r += 1;
            },
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
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Reader = Io.Reader;
const count = std.mem.count;
const startsWith = std.mem.startsWith;
const assert = std.debug.assert;
const indexOfPos = std.mem.indexOfPos;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const indexOfAnyPos = std.mem.indexOfAnyPos;
const splitScalar = std.mem.splitScalar;
const allocPrint = std.fmt.allocPrint;
const parseInt = std.fmt.parseInt;
const log = std.log.scoped(.git_patch);

const CURL = @import("curl.zig");
const verse = @import("verse");
const abx = verse.abx;
