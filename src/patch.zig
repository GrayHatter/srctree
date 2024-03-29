const std = @import("std");

const mem = std.mem;
const Allocator = mem.Allocator;

const CURL = @import("curl.zig");
const Bleach = @import("bleach.zig");
const Endpoint = @import("endpoint.zig");
const Response = Endpoint.Response;
const HTML = Endpoint.HTML;
const DOM = Endpoint.DOM;

pub const Patch = struct {
    patch: []const u8,

    pub fn isValid(_: Patch) bool {
        return true; // lol, you thought this did something :D
    }

    pub fn filesSlice(self: Patch, a: Allocator) ![][]const u8 {
        const count = mem.count(u8, self.patch, "\ndiff --git a/") +
            @as(usize, if (mem.startsWith(u8, self.patch, "diff --git a/")) 1 else 0);
        if (count == 0) return error.PatchInvalid;
        var files = try a.alloc([]const u8, count);
        errdefer a.free(files);
        var fidx: usize = 0;
        var start: usize = mem.indexOfPos(u8, self.patch, 0, "diff --git a/") orelse {
            return error.PatchInvalid;
        };
        var end: usize = start;
        while (start < self.patch.len) {
            end = mem.indexOfPos(u8, self.patch, start + 1, "\ndiff --git a/") orelse self.patch.len;
            files[fidx] = self.patch[start..end];
            start = end;
            fidx += 1;
        }
        return files;
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

fn parseHeader() void {}

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

// TODO move this function, I tried it, and now I hate it!
pub fn patchHtml(a: Allocator, patch: []const u8) ![]HTML.Element {
    var p = Patch{ .patch = patch };
    const diffs = p.filesSlice(a) catch return &[0]HTML.Element{};
    defer a.free(diffs);

    var dom = DOM.new(a);

    dom = dom.open(HTML.patch());
    for (diffs) |diff| {
        var h = Header{ .data = diff };
        h.parse() catch |e| {
            std.debug.print("error {}\n", .{e});
            std.debug.print("patch {s}\n", .{diff});
            continue;
        };
        const body = h.changes orelse continue;

        dom = dom.open(HTML.diff());
        dom.push(HTML.element("filename", h.filename.right orelse "File Deleted", null));
        dom = dom.open(HTML.element("changes", null, null));
        dom.pushSlice(diffLine(a, body));
        dom = dom.close();
        dom = dom.close();
    }
    dom = dom.close();
    return dom.done();
}

pub fn diffLine(a: Allocator, diff: []const u8) []HTML.Element {
    var dom = DOM.new(a);

    const count = std.mem.count(u8, diff, "\n");
    var litr = std.mem.split(u8, diff, "\n");
    for (0..count + 1) |_| {
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
