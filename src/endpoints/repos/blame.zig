const BlamePage = PageData("blame.html");

const style_blocks: [10][]const u8 = .{
    " blame-age-0",
    " blame-age-1",
    " blame-age-2",
    " blame-age-3",
    " blame-age-4",
    " blame-age-5",
    " blame-age-6",
    " blame-age-7",
    " blame-age-8",
    " blame-age-old",
};
pub fn blame(f: *Frame) Router.Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    std.debug.assert(rd.verb.? == .blame);
    const blame_file = (rd.path orelse return error.InvalidURI).rest();

    var repo = (repos.open(rd.name, .public) catch return error.Unknown) orelse return error.Unrouteable;
    defer repo.raze();

    var actions = repo.getAgent(f.alloc);
    actions.cwd = if (!repo.bare) repo.dir.openDir("..", .{}) catch return error.Unknown else repo.dir;
    defer if (!repo.bare) actions.cwd.?.close();
    const git_blame = actions.blame(blame_file) catch return error.Unknown;

    const map, const lines = parseBlame(f.alloc, git_blame) catch return error.Unknown;
    var source_lines = std.ArrayList(u8).init(f.alloc);
    for (lines) |line| {
        try source_lines.appendSlice(line.line);
        try source_lines.append('\n');
    }

    const count = map.count();
    const tsblocks = f.alloc.alloc(i64, count) catch return error.Unknown;
    for (tsblocks, map.values()) |*dst, src| {
        dst.* = src.committer.timestamp;
    }
    std.mem.sort(i64, tsblocks, {}, intSort);
    const min: usize = @abs(tsblocks[tsblocks.len - 1]);
    const max: usize = @abs(tsblocks[0]);
    const range = (max - min) / (style_blocks.len - 1);

    for (map.values()) |*dst| {
        const block = (@abs(dst.committer.timestamp) - min) / range;
        dst.age_block = @truncate(style_blocks.len - 1 - block);
    }

    const formatted = if (Highlight.Language.guessFromFilename(blame_file)) |lang| fmt: {
        var pre = try Highlight.highlight(f.alloc, lang, source_lines.items);
        break :fmt pre[28..][0 .. pre.len - 38];
    } else verse.abx.Html.cleanAlloc(f.alloc, source_lines.items) catch return error.Unknown;

    var litr = std.mem.splitScalar(u8, formatted, '\n');
    for (lines) |*line|
        line.line = litr.next() orelse break;

    const wrapped_blames = try wrapLineNumbersBlame(f.alloc, lines, map, rd.name, f.user != null);

    var page = BlamePage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = f.response_data.get(S.BodyHeaderHtml) catch return error.Unknown,
        .filename = try verse.abx.Html.cleanAlloc(f.alloc, blame_file),
        .blame_lines = wrapped_blames,
    });

    f.status = .ok;
    try f.sendPage(&page);
}

fn intSort(_: void, l: i64, r: i64) bool {
    return l > r;
}

fn wrapLineNumbersBlame(
    a: Allocator,
    blames: []BlameLine,
    map: BlameMap,
    repo_name: []const u8,
    include_email: bool,
) ![]S.BlameLines {
    const b_lines = try a.alloc(S.BlameLines, blames.len);
    const shas = try a.alloc([8]u8, blames.len);
    var prev_sha: SHA = .{ .bin = @splat(0xff) };
    for (blames, b_lines, shas, 0..) |src, *dst, *sha, i| {
        const skip = src.sha.eql(prev_sha);
        if (!skip) prev_sha = src.sha;
        const bcommit = map.get(src.sha) orelse unreachable;
        const email = if (!include_email) "" else verse.abx.Html.cleanAlloc(a, bcommit.author.email) catch unreachable;
        sha.* = src.sha.hex()[0..8].*;
        dst.* = .{
            .repo_name = repo_name,
            .m_sha = if (skip) null else sha,
            .sha = sha,
            .time_style = style_blocks[bcommit.age_block],
            .author_email = .{
                .author = if (skip) null else verse.abx.Html.cleanAlloc(a, bcommit.author.name) catch unreachable,
                .email = email,
            },
            .time = if (skip) null else try Humanize.unix(bcommit.author.timestamp).printAlloc(a),
            .num = i + 1,
            .line = src.line,
        };
    }
    return b_lines;
}

const BlameCommit = struct {
    parent: ?[]const u8 = null,
    title: []const u8,
    filename: []const u8,
    author: Git.Actor,
    committer: Git.Actor,
    age_block: u8 = 0,
};

const BlameLine = struct {
    sha: SHA,
    line: []const u8,
};

const BlameMap = std.AutoArrayHashMap(SHA, BlameCommit);

fn parseBlame(a: Allocator, blame_txt: []const u8) !struct { BlameMap, []BlameLine } {
    var map = BlameMap.init(a);
    const count = std.mem.count(u8, blame_txt, "\n\t");
    const lines = try a.alloc(BlameLine, count);
    var in_lines = std.mem.splitScalar(u8, blame_txt, '\n');

    for (lines) |*blm| {
        const line = in_lines.next() orelse break;
        if (line.len < 40) unreachable;
        blm.sha = .init(line[0..40]);
        const gp = try map.getOrPut(blm.sha);
        const bcmt: *BlameCommit = gp.value_ptr;
        if (!gp.found_existing) {
            var parent: ?[]const u8 = null;
            var filename: ?[]const u8 = null;
            var title: ?[]const u8 = null;
            var author_name: ?[]const u8 = null;
            var author_email: ?[]const u8 = null;
            var author_ts: ?i64 = null;
            var author_tz: i32 = 0;
            var committer_name: ?[]const u8 = null;
            var committer_email: ?[]const u8 = null;
            var committer_ts: ?i64 = null;
            var committer_tz: i32 = 0;
            while (true) {
                const next = in_lines.next() orelse return error.UnexpectedEndOfBlame;
                if (next[0] == '\t') {
                    blm.*.line = next[1..];
                    break;
                }

                if (startsWith(u8, next, "author ")) {
                    author_name = next["author ".len..];
                } else if (startsWith(u8, next, "author-mail ")) {
                    author_email = next["author-mail ".len..];
                } else if (startsWith(u8, next, "author-time ")) {
                    author_ts = try std.fmt.parseInt(i64, next["author-time ".len..], 10);
                } else if (startsWith(u8, next, "author-tz ")) {
                    author_tz = try std.fmt.parseInt(i32, next["author-tz ".len..], 10);
                } else if (startsWith(u8, next, "summary ")) {
                    title = next["summary ".len..];
                } else if (startsWith(u8, next, "previous ")) {
                    parent = next["previous ".len..][0..40];
                } else if (startsWith(u8, next, "filename ")) {
                    filename = next["filename ".len..];
                } else if (startsWith(u8, next, "committer ")) {
                    committer_name = next["committer ".len..];
                } else if (startsWith(u8, next, "committer-mail ")) {
                    committer_email = next["committer-mail ".len..];
                } else if (startsWith(u8, next, "committer-time ")) {
                    committer_ts = try std.fmt.parseInt(i64, next["committer-time ".len..], 10);
                } else if (startsWith(u8, next, "committer-tz ")) {
                    committer_tz = try std.fmt.parseInt(i32, next["committer-tz ".len..], 10);
                } else {
                    std.debug.print("unexpected blame data '{s}' \n", .{next});
                    continue;
                }
            }
            bcmt.* = .{
                .parent = parent,
                .title = title orelse return error.UnexpectedEndOfBlame,
                .filename = filename orelse return error.UnexpectedEndOfBlame,
                .author = .{
                    .name = author_name orelse return error.BlameAuthorIncomplete,
                    .email = Git.Actor.trimEmail(author_email orelse return error.BlameAuthorIncomplete),
                    .timestr = "",
                    .tzstr = "",
                    .timestamp = author_ts orelse return error.BlameAuthorIncomplete,
                    .tz = author_tz,
                },
                .committer = .{
                    .name = author_name orelse return error.BlameCommitterIncomplete,
                    .email = Git.Actor.trimEmail(author_name orelse return error.BlameCommitterIncomplete),
                    .timestr = "",
                    .tzstr = "",
                    .timestamp = author_ts orelse return error.BlameCommitterIncomplete,
                    .tz = author_tz,
                },
            };
        } else {
            blm.line = in_lines.next().?[1..];
        }
    }

    return .{ map, lines };
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;

const tree = @import("tree.zig").tree;
const repos_ = @import("../repos.zig");
const RouteData = repos_.RouteData;
const Humanize = @import("../../humanize.zig");
const repos = @import("../../repos.zig");
const Git = @import("../../git.zig");
const SHA = Git.SHA;
const Highlight = @import("../../syntax-highlight.zig");

const verse = @import("verse");
const Frame = verse.Frame;
const S = verse.template.Structs;
const PageData = verse.template.PageData;
const Router = verse.Router;
