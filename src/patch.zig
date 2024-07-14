const std = @import("std");

const mem = std.mem;
const Allocator = mem.Allocator;
const count = mem.count;
const startsWith = mem.startsWith;
const assert = std.debug.assert;
const eql = std.mem.eql;

const CURL = @import("curl.zig");
const Bleach = @import("bleach.zig");
const Endpoint = @import("endpoint.zig");
const Response = Endpoint.Response;
const HTML = Endpoint.HTML;
const DOM = Endpoint.DOM;

pub const Patch = @This();

blob: []const u8,
diffs: ?[]Diff = null,

pub const Diff = struct {
    header: Header,
    changes: ?[]const u8 = null,

    pub const Header = struct {
        data: []const u8,
        preamble: []const u8,
        index: ?[]const u8 = null,
        filename: struct {
            left: ?[]const u8 = null,
            right: ?[]const u8 = null,
        } = .{},

        /// returns the input line if it's a valid extended header
        fn parseHeader(line: []const u8) ?[]const u8 {
            // TODO
            // old mode <mode>
            // new mode <mode>
            // deleted file mode <mode>
            // new file mode <mode>
            // copy from <path>
            // copy to <path>
            // rename from <path>
            // rename to <path>
            // similarity index <number>
            // dissimilarity index <number>
            // index <hash>..<hash> <mode>
            if (startsWith(u8, line, "index ")) {
                // TODO parse index correctly
                return line;
            } else if (startsWith(u8, line, "similarity index")) {
                // TODO parse similarity correctly
                return line;
            }

            return null;
        }

        fn parseFilename(_: []const u8) ?[]const u8 {
            return null;
        }

        pub fn parse(self: *Header) !void {
            var d = self.data;
            assert(startsWith(u8, d, "diff --git a/"));
            var i: usize = 0;
            while (d[i] != '\n' and i < d.len) i += 1;
            self.preamble = d[0..i];
            d = d[i + 1 ..];

            i = 0;
            while (d[i] != '\n' and i < d.len) i += 1;
            self.index = parseHeader(d[0 .. i + 1]) orelse return error.UnableToParsePatchHeader;
            if (startsWith(u8, self.index.?, "index ")) {
                d = d[i + 1 ..];

                // Left Filename
                if (d.len < 6 or !eql(u8, d[0..4], "--- ")) return error.UnableToParsePatchHeader;
                d = d[4..];

                i = 0;
                while (d[i] != '\n' and i < d.len) i += 1;
                self.filename.left = d[2..i];

                if (d.len < 4 or !eql(u8, d[0..2], "a/")) {
                    if (d.len < 10 or !eql(u8, d[0..10], "/dev/null\n")) return error.UnableToParsePatchHeader;
                    self.filename.left = null;
                }
                d = d[i + 1 ..];

                // Right Filename
                if (d.len < 6 or !eql(u8, d[0..4], "+++ ")) return error.UnableToParsePatchHeader;
                d = d[4..];

                i = 0;
                while (d[i] != '\n' and i < d.len) i += 1;
                self.filename.right = d[2..i];

                if (d.len < 4 or !eql(u8, d[0..2], "b/")) {
                    if (d.len < 10 or !eql(u8, d[0..10], "/dev/null\n")) return error.UnableToParsePatchHeader;
                    self.filename.right = null;
                }
                d = d[i + 1 ..];

                // Block headers
                if (d.len < 20 or !eql(u8, d[0..4], "@@ -")) return error.BlockHeaderMissing;
                if (mem.indexOfPos(u8, d[4..], 0, " @@") == null) return error.BlockHeaderInvalid;
            } else if (startsWith(u8, self.index.?, "similarity index ")) {
                // TODO
            } else return error.UnableToParsePatchHeader;
        }
    };

    pub fn init(blob: []const u8) !Diff {
        var d: Diff = .{
            .header = Header{
                .data = blob,
                .preamble = undefined,
            },
        };
        try d.parse();
        return d;
    }

    pub fn parse(d: *Diff) !void {
        try d.header.parse();
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

pub fn diffsSlice(self: Patch, a: Allocator) ![]Diff {
    const diff_count = count(u8, self.blob, "\ndiff --git a/") +
        @as(usize, if (mem.startsWith(u8, self.blob, "diff --git a/")) 1 else 0);
    if (diff_count == 0) return error.PatchInvalid;
    const diffs = try a.alloc(Diff, diff_count);
    errdefer a.free(diffs);
    var start: usize = mem.indexOfPos(u8, self.blob, 0, "diff --git a/") orelse {
        return error.PatchInvalid;
    };
    var end: usize = start;
    for (diffs) |*diff| {
        assert(self.blob[start] != '\n');
        end = if (mem.indexOfPos(u8, self.blob, start + 1, "\ndiff --git a/")) |s| s + 1 else self.blob.len;
        diff.* = try Diff.init(self.blob[start..end]);
        start = end;
    }
    return diffs;
}

pub const DiffStat = struct {
    files: usize,
    additions: usize,
    deletions: usize,
    total: isize,
};

pub fn diffstat(p: Patch) DiffStat {
    const a = count(u8, p.blob, "\n+");
    const d = count(u8, p.blob, "\n-");
    const files = count(u8, p.blob, "\ndiff --git a/");
    return .{
        .files = files,
        .additions = a,
        .deletions = d,
        .total = @intCast(a -| d),
    };
}

fn fetch(a: Allocator, uri: []const u8) ![]u8 {
    // disabled until tls1.2 is supported
    // var client = std.http.client{
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
    return Patch{ .blob = try fetch(a, uri) };
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
    const diffs: []Diff = try patch.diffsSlice(a);
    defer a.free(diffs);
    try std.testing.expectEqual(1, diffs.len);
}

test diffsSlice {
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
    const diffs = try p.diffsSlice(a);
    defer a.free(diffs);
    try std.testing.expect(diffs.len == 2);
    const h = diffs[1].header;
    try std.testing.expectEqualStrings(h.filename.left.?, "build.zig");
    try std.testing.expectEqualStrings(h.filename.left.?, h.filename.right.?);
}
