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
        // Filename
        const left_s = 7 + (mem.indexOf(u8, d, "\n--- a/") orelse return error.PatchInvalid);
        const left_e = mem.indexOfPos(u8, d, left_s, "\n") orelse return error.PatchInvalid;
        self.filename.left = d[left_s..left_e];
        const right_s = 7 + (mem.indexOfPos(u8, d, left_e, "\n+++ b/") orelse return error.PatchInvalid);
        const right_e = mem.indexOfPos(u8, d, right_s, "\n") orelse return error.PatchInvalid;
        self.filename.right = d[right_s..right_e];
        // Block headers
        const block_s = mem.indexOf(u8, d, "\n@@ ") orelse return error.BlockHeaderMissing;
        const block_e = mem.indexOf(u8, d, " @@") orelse return error.BlockHeaderMissing;
        const block = d[block_s + 4 .. block_e];
        var bi = mem.indexOf(u8, block, " ") orelse return error.BlockInvalid;
        const left = block[0..bi];
        const right = block[bi + 1 ..];
        _ = left;
        _ = right;
        // Changes
        const block_nl = mem.indexOfPos(u8, d, block_e, "\n") orelse return error.BlockHeaderInvalid;
        if (d.len > block_nl) self.changes = d[block_nl + 1 ..];
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

    var curl = try CURL.curlRequest(a, uri);
    if (curl.code != 200) return error.UnexpectedResponseCode;

    if (curl.body) |b| return b;
    return error.EpmtyReponse;
}

pub fn loadRemote(a: Allocator, uri: []const u8) !Patch {
    return Patch{ .patch = try fetch(a, uri) };
}

pub fn patchHtml(a: Allocator, patch: []const u8) ![]HTML.Element {
    var p = Patch{ .patch = patch };
    var diffs = p.filesSlice(a) catch return &[0]HTML.Element{};
    defer a.free(diffs);

    var dom = DOM.new(a);

    dom = dom.open(HTML.patch());
    for (diffs) |diff| {
        var h = Header{ .data = diff };
        h.parse() catch continue;
        const body = h.changes orelse continue;

        dom = dom.open(HTML.diff());
        dom.push(HTML.element("filename", h.filename.left orelse "File name empty", null));
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
            var big = a.realloc(clean, clean.len * 2) catch unreachable;
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
    var files = try p.filesSlice(a);
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
