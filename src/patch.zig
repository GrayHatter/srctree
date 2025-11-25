blob: []const u8,
diffs: ?[]Diff = null,

const Patch = @This();

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

pub const Diff = struct {
    blob: []const u8,
    header: Header,
    changes: ?[]const u8 = null,
    stat: Diff.Stat,
    filename: ?[]const u8 = null,
    blocks: ?[][]const u8 = null,

    pub const Stat = struct {
        additions: usize,
        deletions: usize,
        total: isize,
    };

    const FileType = enum(u4) {
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

    pub const Mode = packed struct(u16) {
        other: FSPerm,
        group: FSPerm,
        owner: FSPerm,
        stick: FSPerm = .{},
        file_type: FileType,

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
        blob: []const u8,
        index: ?[]const u8,
        change: Change,

        const Change = union(enum) {
            none: void,
            binary: void,
            newfile: Mode,
            deletion: Mode,
            copy: SrcDst,
            rename: SrcDst,
            mode: SrcDst,
            similarity: []const u8,
            dissimilarity: []const u8,
        };

        const SrcDst = struct {
            src: []const u8,
            dst: []const u8,
        };

        fn parse(src: []const u8) !Header {
            var pos: usize = 0;
            var current = src[0..];
            var blob: []const u8 = src[0..];
            var change: Change = .{ .none = {} };
            var index: ?[]const u8 = null;
            while (true) {
                if (startsWith(u8, current, "index ")) {
                    // TODO parse index correctly
                    const nl = indexOf(u8, current, "\n") orelse return error.InvalidHeader;
                    index = current[0..nl];
                } else {
                    const nl = indexOf(u8, current, "\n") orelse break;
                    if (startsWith(u8, current, "similarity index")) {
                        // TODO parse similarity correctly
                        change = .{ .similarity = current };
                    } else if (startsWith(u8, current, "old mode ")) {
                        change = .{ .mode = undefined };
                    } else if (startsWith(u8, current, "new mode ")) {
                        change = .{ .mode = undefined };
                    } else if (startsWith(u8, current, "deleted file mode ")) {
                        change = .{ .deletion = try .fromStr(current["deleted file mode ".len..][0..6].*) };
                    } else if (startsWith(u8, current, "new file mode ")) {
                        change = .{ .newfile = try .fromStr(current["new file mode ".len..][0..6].*) };
                    } else if (startsWith(u8, current, "copy from ")) {
                        change = .{ .copy = .{
                            .src = current["copy from ".len..nl],
                            .dst = undefined,
                        } };
                    } else if (startsWith(u8, current, "copy to ")) {
                        change = .{ .copy = .{
                            .src = change.copy.src,
                            .dst = current["copy to ".len..nl],
                        } };
                    } else if (startsWith(u8, current, "rename from ")) {
                        change = .{ .rename = .{
                            .src = current["rename from ".len..nl],
                            .dst = undefined,
                        } };
                    } else if (startsWith(u8, current, "rename to ")) {
                        change = .{ .rename = .{
                            .src = change.rename.src,
                            .dst = current["rename to ".len..nl],
                        } };
                    } else if (startsWith(u8, current, "dissimilarity index ")) {
                        change = .{ .dissimilarity = current };
                    } else if (startsWith(u8, current, "Binary files ")) {
                        change = .{ .binary = {} };
                    } else {
                        // TODO search for '\n[^+- ]' and return change body
                        // size to caller
                        if (startsWith(u8, current, "--- ") or
                            startsWith(u8, current, "+++ ") or
                            startsWith(u8, current, "@@"))
                        {
                            break;
                        } else if (current.len > 1) {
                            std.debug.print("ERROR: unsupported header {s}\n", .{current});
                        }
                    }
                }
                pos = std.mem.indexOfPos(u8, src, pos + 1, "\n") orelse break;
                blob = src[0 .. pos + 1];
                current = src[pos + 1 ..];
            }
            if (index == null and change == .none) return error.IncompleteHeader;
            return .{
                .blob = blob,
                .index = index,
                .change = change,
            };
        }
    };

    fn parseFilename(_: []const u8) ?[]const u8 {
        return null;
    }

    /// I'm so sorry for these crimes... in my defense, I got distracted
    /// while refactoring :<
    pub fn parse(self: *Diff) !?[]const u8 {
        var d = self.blob;
        assert(startsWith(u8, d, "diff --git a/"));
        var i: usize = 0;
        while (d[i] != '\n' and i < d.len) i += 1;
        d = d[i + 1 ..];

        i = 0;
        //while (i < d.len and d[i] != '\n') i += 1;
        //if (i == d.len) return null;
        const header: Header = try .parse(d[0..]);
        self.header = header;
        d = d[header.blob.len..];

        switch (header.change) {
            .deletion, .binary => return &.{},
            else => {},
        }

        if (header.index != null) {
            // TODO redact and user headers
            // Left Filename
            if (d.len < 6 or !eql(u8, d[0..4], "--- ")) {
                std.debug.print("{s}\n", .{self.blob});
                return error.UnableToParsePatchHeader;
            }
            d = d[4..];

            i = 0;
            while (d[i] != '\n' and i < d.len) i += 1;
            self.filename = d[2..i];

            if (d.len < 4 or !eql(u8, d[0..2], "a/")) {
                if (d.len < 10 or !eql(u8, d[0..10], "/dev/null\n")) return error.UnableToParsePatchHeader;
                self.filename = null;
            }
            d = d[i + 1 ..];

            // Right Filename
            if (d.len < 6 or !eql(u8, d[0..4], "+++ ")) return error.UnableToParsePatchHeader;
            d = d[4..];

            i = 0;
            while (d[i] != '\n' and i < d.len) i += 1;
            const right_name = d[2..i];

            if (d.len < 4 or !eql(u8, d[0..2], "b/")) {
                if (d.len < 10 or !eql(u8, d[0..10], "/dev/null\n")) return error.UnableToParsePatchHeader;
                self.filename = right_name;
            }
            d = d[i + 1 ..];

            // Block headers
            if (d.len < 20 or !eql(u8, d[0..4], "@@ -")) return error.BlockHeaderMissing;
            _ = indexOf(u8, d[4..], " @@") orelse return error.BlockHeaderInvalid;
        }
        return d;
    }

    pub fn init(blob: []const u8) !Diff {
        var d: Diff = .{
            .blob = blob,
            .header = undefined,
            .stat = .{
                .additions = count(u8, blob, "\n+"),
                .deletions = count(u8, blob, "\n-"),
                .total = @intCast(count(u8, blob, "\n+") -| count(u8, blob, "\n-")),
            },
        };
        d.changes = d.parse() catch {
            log.err("{s}", .{blob});
            unreachable;
        };
        return d;
    }

    /// Leaks
    pub fn blocksAlloc(self: *Diff, a: Allocator) ![]const []const u8 {
        var acount = count(u8, self.changes.?, "\n@@");
        if (startsWith(u8, self.changes.?, "@@")) acount += 1 else acount += 0;
        self.blocks = try a.alloc([]const u8, acount);
        var i: usize = 0;
        var pos: usize = indexOf(u8, self.changes.?, "@@") orelse return self.blocks.?;
        while (indexOf(u8, self.changes.?[pos + 1 ..], "\n@@")) |end| {
            self.blocks.?[i] = self.changes.?[pos..][0 .. end + 1];
            pos += end + 2;
            i += 1;
        }
        self.blocks.?[i] = self.changes.?[pos..];

        return self.blocks.?;
    }
};

pub fn init(patch: []const u8) Patch {
    return .{
        .blob = patch,
    };
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

pub const Stat = struct {
    files: usize,
    additions: usize,
    deletions: usize,
    total: isize,
};

pub fn patchStat(p: Patch) Stat {
    const a = count(u8, p.blob, "\n+");
    const d = count(u8, p.blob, "\n-");
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
        std.debug.print("request code {}\n", .{req.status});
        std.debug.print("request body {s}\n", .{response.items});
        return try response.toOwnedSlice(a);
    } else |err| {
        std.debug.print("stdlib request failed with error {}\n", .{err});
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

pub const DiffLine = union(enum) {
    hdr: []const u8,
    add: Numbered,
    del: Numbered,
    ctx: Numbered,
    empty: void,

    pub const Numbered = struct {
        number: u32,
        number_right: u32 = 0,
        text: []const u8,
    };
};

pub const Split = struct {
    left: []DiffLine,
    right: []DiffLine,
};

fn lineNumberFromHeader(str: []const u8) !struct { u32, u32 } {
    std.debug.assert(std.mem.startsWith(u8, str, "@@ -"));
    var idx: usize = 4;
    const left: u32 = if (indexOfAnyPos(u8, str, idx, " ,")) |end|
        try std.fmt.parseInt(u32, str[idx..end], 10)
    else
        return error.InvalidHeader;

    idx = indexOfScalarPos(u8, str, idx, '+') orelse return error.InvalidHeader;
    const right: u32 = if (indexOfAnyPos(u8, str, idx, " ,")) |end|
        try std.fmt.parseInt(u32, str[idx..end], 10)
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

    var left: ArrayList(DiffLine) = .{};
    var right: ArrayList(DiffLine) = .{};
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

pub fn diffLineHtmlUnified(a: Allocator, diff: []const u8) ![]DiffLine {
    const clean = allocPrint(a, "{f}", .{abx.Html{ .text = diff }}) catch unreachable;
    const line_count = std.mem.count(u8, clean, "\n");
    var lines: ArrayList(DiffLine) = .{};
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
const ArrayList = std.ArrayListUnmanaged;
const Io = std.Io;
const count = std.mem.count;
const startsWith = std.mem.startsWith;
const assert = std.debug.assert;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const indexOfPos = std.mem.indexOfPos;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const indexOfAnyPos = std.mem.indexOfAnyPos;
const splitScalar = std.mem.splitScalar;
const allocPrint = std.fmt.allocPrint;
const log = std.log.scoped(.git_patch);

const CURL = @import("curl.zig");
const verse = @import("verse");
const abx = verse.abx;
const Response = verse.Response;
const HTML = verse.template.html;
const DOM = verse.template.html.DOM;
