const std = @import("std");

const mem = std.mem;
const Allocator = mem.Allocator;
const count = mem.count;
const startsWith = mem.startsWith;
const assert = std.debug.assert;

const CURL = @import("curl.zig");
const Bleach = @import("bleach.zig");
const Endpoint = @import("endpoint.zig");
const Response = Endpoint.Response;
const HTML = Endpoint.HTML;
const DOM = Endpoint.DOM;

pub const Diff = struct {
    header: Header,
    changes: ?[]const u8 = null,
};

pub const Patch = struct {
    // TODO reduce namespace
    patch: []const u8,
    diffs: ?[]Diff = null,

    pub fn init(patch: []const u8) Patch {
        return .{
            .patch = patch,
        };
    }

    pub fn isValid(_: Patch) bool {
        return true; // lol, you thought this did something :D
    }

    pub fn filesSlice(self: Patch, a: Allocator) ![][]const u8 {
        const fcount = count(u8, self.patch, "\ndiff --git a/") +
            @as(usize, if (mem.startsWith(u8, self.patch, "diff --git a/")) 1 else 0);
        if (fcount == 0) return error.PatchInvalid;
        const files = try a.alloc([]const u8, fcount);
        errdefer a.free(files);
        var start: usize = mem.indexOfPos(u8, self.patch, 0, "diff --git a/") orelse {
            return error.PatchInvalid;
        };
        var end: usize = start;
        for (files) |*file| {
            assert(self.patch[start] != '\n');
            end = if (mem.indexOfPos(u8, self.patch, start + 1, "\ndiff --git a/")) |s| s + 1 else self.patch.len;
            file.* = self.patch[start..end];
            start = end;
        }
        return files;
    }

    pub const DiffStat = struct {
        files: usize,
        additions: usize,
        deletions: usize,
        total: isize,
    };

    pub fn diffstat(p: Patch) DiffStat {
        const a = count(u8, p.patch, "\n+");
        const d = count(u8, p.patch, "\n-");
        const files = count(u8, p.patch, "\ndiff --git a/");
        return .{
            .files = files,
            .additions = a,
            .deletions = d,
            .total = @intCast(a -| d),
        };
    }
};

pub const Header = struct {
    data: ?[]const u8 = null,
    filename: struct {
        left: ?[]const u8 = null,
        right: ?[]const u8 = null,
    } = .{},
    changes: ?[]const u8 = null,

    pub fn parse(self: *Header) !void {
        var d = self.data orelse return error.NoData;
        var pos: usize = 0;
        assert(startsWith(u8, d, "diff --git a/"));
        // TODO rewrite imperatively
        if (mem.indexOfPos(u8, d, pos, "\n--- a/")) |i| {
            if (mem.indexOfPos(u8, d, i + 7, "\n")) |end| {
                self.filename.left = d[i + 7 .. end];
                pos = end;
            } else return error.UnableToParsePatchHeader;
        } else if (mem.indexOfPos(u8, d, pos, "\n--- /dev/null")) |i| {
            if (mem.indexOfPos(u8, d, i + 5, "\n")) |end| {
                self.filename.left = d[i + 5 .. end];
                pos = end;
            } else return error.UnableToParsePatchHeader;
        } else {
            return error.UnableToParsePatchHeader;
        }

        if (mem.indexOfPos(u8, d, pos, "\n+++ b/")) |i| {
            if (mem.indexOfPos(u8, d, i + 7, "\n")) |end| {
                self.filename.right = d[i + 7 .. end];
                pos = end;
            } else return error.UnableToParsePatchHeader;
        } else {
            return error.UnableToParsePatchHeader;
        }

        // Block headers
        if (mem.indexOfPos(u8, d, pos, "\n@@ ")) |i| {
            if (mem.indexOfPos(u8, d, i, " @@")) |end| {
                if (mem.indexOfPos(u8, d, end, "\n")) |change_start| {
                    if (d.len > change_start) self.changes = d[change_start + 1 ..];
                } else return error.BlockHeaderInvalid;
            } else return error.BlockHeaderMissing;
        } else return error.BlockHeaderMissing;
    }
};

fn fetch(a: Allocator, uri: []const u8) ![]u8 {
    // Disabled until TLS1.2 is supported
    // var client = std.http.Client{
    //     .allocator = a,
    // };
    // defer client.deinit();

    // var request = client.fetch(a, .{
    //     .location = .{ .url = uri },
    // });
    // if (request) |*req| {
    //     defer req.deinit();
    //     std.debug.print("request code {}\n", .{req.status});
    //     if (req.body) |b| {
    //         std.debug.print("request body {s}\n", .{b});
    //         return a.dupe(u8, b);
    //     }
    // } else |err| {
    //     std.debug.print("stdlib request failed with error {}\n", .{err});
    // }

    const curl = try CURL.curlRequest(a, uri);
    if (curl.code != 200) return error.UnexpectedResponseCode;

    if (curl.body) |b| return b;
    return error.EpmtyReponse;
}

pub fn loadRemote(a: Allocator, uri: []const u8) !Patch {
    return Patch{ .patch = try fetch(a, uri) };
}

pub fn diffLine(a: Allocator, diff: []const u8) []HTML.Element {
    var dom = DOM.new(a);

    const line_count = std.mem.count(u8, diff, "\n");
    var litr = std.mem.split(u8, diff, "\n");
    for (0..line_count + 1) |_| {
        const a_add = &HTML.Attr.class("add");
        const a_del = &HTML.Attr.class("del");
        const dirty = litr.next().?;
        var clean = a.alloc(u8, @max(64, dirty.len * 2)) catch unreachable;
        clean = Bleach.sanitize(dirty, clean, .{}) catch bigger: {
            const big = a.realloc(clean, clean.len * 2) catch unreachable;
            break :bigger Bleach.sanitize(dirty, big, .{}) catch unreachable;
        };
        const attr: ?[]const HTML.Attr = if (clean.len > 0 and (clean[0] == '-' or clean[0] == '+'))
            if (clean[0] == '-') a_del else a_add
        else
            null;
        dom.dupe(HTML.span(clean, attr));
    }

    return dom.done();
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
    const patch = Patch.init(rn_patch);
    const files = try patch.filesSlice(a);
    defer a.free(files);
}

test "filesSlice" {
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
        .patch = a_patch,
    };
    const files = try p.filesSlice(a);
    defer a.free(files);
    try std.testing.expect(files.len == 2);
    var h: Header = undefined;
    for (files) |f| {
        h = Header{
            .data = @constCast(f),
        };
        try h.parse();
    }
    try std.testing.expectEqualStrings(h.filename.left.?, "build.zig");
    try std.testing.expectEqualStrings(h.filename.left.?, h.filename.right.?);
}
