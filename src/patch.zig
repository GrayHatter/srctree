blob: []const u8,
diffs: ?[]Diff = null,

const Patch = @This();

pub const FSPerm = packed struct(u8) {
    read: bool,
    write: bool,
    execute: bool,
    sticky: bool,
    padding: u4,

    pub const default: FSPerm = .{
        .read = false,
        .write = false,
        .execute = false,
        .stick = false,
        .padding = 0,
    };
};

test FSPerm {
    var target: FSPerm = undefined;
    const modify: *u8 = @ptrCast(&target);
    modify.* = 7;
    try std.testing.expectEqual(true, target.read);
    try std.testing.expectEqual(true, target.write);
    try std.testing.expectEqual(true, target.execute);
    try std.testing.expectEqual(false, target.sticky);
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

    const Mode = [4]u8;

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

        fn parseMode(str: []const u8) !Mode {
            if (str.len < 6 or str[0] != '1' or str[1] != '0' or str[2] != '0') {
                std.debug.print("invalid mode string found {s}\n", .{str});
                return error.InvalidMode;
            }
            var mode: Mode = .{ 0, 0, 0, 0 };
            for (str[3..6], mode[1..4]) |s, *m| switch (s) {
                '0' => m.* = 0,
                '1' => m.* = 1,
                '2' => m.* = 2,
                '3' => m.* = 3,
                '4' => m.* = 4,
                '5' => m.* = 5,
                '6' => m.* = 6,
                '7' => m.* = 7,
                else => {
                    std.debug.print("invalid mode string found {s}\n", .{str});
                    return error.InvalidMode;
                },
            };

            return mode;
        }

        fn parse(src: []const u8) !Header {
            var pos: usize = 0;
            var current = src[0..];
            var blob: []const u8 = src[0..];
            var change: Change = .{ .none = {} };
            var index: ?[]const u8 = null;
            while (true) {
                if (startsWith(u8, current, "index ")) {
                    // TODO parse index correctly
                    const nl = indexOf(u8, src, "\n") orelse return error.InvalidHeader;
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
                        change = .{ .deletion = try parseMode(current["deleted file mode ".len..]) };
                    } else if (startsWith(u8, current, "new file mode ")) {
                        change = .{ .newfile = try parseMode(current["new file mode ".len..]) };
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
        const header = try Header.parse(d[0..]);
        d = d[header.blob.len..];

        if (header.index != null) {
            // TODO redact and user headers
            // Left Filename
            if (d.len < 6 or !eql(u8, d[0..4], "--- ")) return error.UnableToParsePatchHeader;
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
        self.header = header;
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
        d.changes = try d.parse();
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

fn fetch(a: Allocator, uri: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = a };
    //defer client.deinit();

    var response = std.ArrayList(u8).init(a);
    defer response.clearAndFree();
    const request = client.fetch(.{
        .location = .{ .url = uri },
        .response_storage = .{ .dynamic = &response },
        .max_append_size = 0xffffff,
    });
    if (request) |req| {
        std.debug.print("request code {}\n", .{req.status});
        std.debug.print("request body {s}\n", .{response.items});
        return try response.toOwnedSlice();
    } else |err| {
        std.debug.print("stdlib request failed with error {}\n", .{err});
    }

    const curl = try CURL.curlRequest(a, uri);
    if (curl.code != 200) return error.UnexpectedResponseCode;

    if (curl.body) |b| return b;
    return error.EpmtyReponse;
}

pub fn loadRemote(a: Allocator, uri: []const u8) !Patch {
    return Patch{ .blob = try fetch(a, uri) };
}

pub fn diffLineHtmlSplit(a: Allocator, diff: []const u8) ![]HTML.Element {
    var dom = DOM.new(a);

    const a_splt = &HTML.Attr.class("split");
    const a_add = &HTML.Attr.class("add");
    const a_del = &HTML.Attr.class("del");
    const a_block = &HTML.Attr.class("block");
    const no_line = &HTML.Attr.class("no-line");

    const clean = verse.abx.Html.cleanAlloc(a, diff) catch unreachable;
    const line_count = std.mem.count(u8, clean, "\n");
    var litr = std.mem.splitScalar(u8, clean, '\n');

    const LinePair = struct {
        text: []const u8,
        attr: ?[]const HTML.Attr,
    };

    var left = std.ArrayList(LinePair).init(a);
    var right = std.ArrayList(LinePair).init(a);
    defer left.clearAndFree();
    defer right.clearAndFree();
    for (0..line_count + 1) |_| {
        const line = litr.next().?;
        if (line.len > 0) {
            switch (line[0]) {
                '-' => {
                    try left.append(.{
                        .text = line[1..],
                        .attr = a_del,
                    });
                },
                '+' => {
                    try right.append(.{
                        .text = line[1..],
                        .attr = a_add,
                    });
                },
                '@' => {
                    try left.append(.{ .text = line, .attr = a_block });
                    try right.append(.{ .text = line, .attr = a_block });
                },
                else => {
                    if (left.items.len > right.items.len) {
                        const rcount = left.items.len - right.items.len;
                        for (0..rcount) |_|
                            try right.append(.{ .text = "", .attr = no_line });
                    } else if (left.items.len < right.items.len) {
                        const lcount = right.items.len - left.items.len;
                        for (0..lcount) |_|
                            try left.append(.{ .text = "", .attr = no_line });
                    }
                    try left.append(.{ .text = line[1..], .attr = null });
                    try right.append(.{ .text = line[1..], .attr = null });
                },
            }
        }
    }

    dom = dom.open(HTML.span(null, a_splt));

    dom = dom.open(HTML.span(null, null));
    for (left.items) |line| {
        dom.dupe(HTML.div(line.text, line.attr));
    }
    dom = dom.close();

    dom = dom.open(HTML.span(null, null));
    for (right.items) |line| {
        dom.dupe(HTML.div(line.text, line.attr));
    }
    dom = dom.close();

    dom = dom.close();

    return dom.done();
}

pub fn diffLineHtmlUnified(a: Allocator, diff: []const u8) []HTML.Element {
    var dom = DOM.new(a);
    dom = dom.open(HTML.span(null, null));

    const clean = verse.abx.Html.cleanAlloc(a, diff) catch unreachable;
    const line_count = std.mem.count(u8, clean, "\n");
    var litr = splitScalar(u8, clean, '\n');
    for (0..line_count + 1) |_| {
        const a_add = &HTML.Attr.class("add");
        const a_del = &HTML.Attr.class("del");
        const a_block = &HTML.Attr.class("block");
        const line = litr.next().?;
        var attr: ?[]const HTML.Attr = null;
        if (line.len > 0) {
            switch (line[0]) {
                '-' => attr = a_del,
                '+' => attr = a_add,
                '@' => attr = a_block,
                else => {},
            }
        }
        dom.dupe(HTML.div(
            if (line.len > 1)
                if (line[0] != '@') line[1..] else line
            else
                "&nbsp;",
            attr,
        ));
    }
    dom = dom.close();
    return dom.done();
}

pub fn diffLineUnifiedSlice(a: Allocator, diffs: []const u8) ![]u8 {
    const elms = diffLineHtmlUnified(a, diffs);
    const list = try a.alloc([]u8, elms.len);
    defer a.free(list);
    for (list, elms) |*l, e| {
        l.* = try std.fmt.allocPrint(a, "{pretty}", .{e});
    }
    defer for (list) |l| a.free(l);
    return try std.mem.join(a, "\n", list);
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

test "parseMode" {
    try std.testing.expectEqual([4]u8{ 0, 4, 4, 4 }, Diff.Header.parseMode("100444"));
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const count = std.mem.count;
const startsWith = std.mem.startsWith;
const assert = std.debug.assert;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const indexOfPos = std.mem.indexOfPos;
const splitScalar = std.mem.splitScalar;

const CURL = @import("curl.zig");
const verse = @import("verse");
const Response = verse.Response;
const HTML = verse.template.html;
const DOM = verse.template.html.DOM;
