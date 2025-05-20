const BlamePage = PageData("blame.html");

pub fn blame(ctx: *Frame) Router.Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    std.debug.assert(std.mem.eql(u8, rd.verb orelse "", "blame"));
    _ = ctx.uri.next();
    const blame_file = ctx.uri.rest();

    var repo = (repos.open(rd.name, .public) catch return error.Unknown) orelse return error.Unrouteable;
    defer repo.raze();

    var actions = repo.getAgent(ctx.alloc);
    actions.cwd = if (!repo.bare) repo.dir.openDir("..", .{}) catch unreachable else repo.dir;
    defer if (!repo.bare) actions.cwd.?.close();
    const git_blame = actions.blame(blame_file) catch unreachable;

    const parsed = parseBlame(ctx.alloc, git_blame) catch unreachable;
    var source_lines = std.ArrayList(u8).init(ctx.alloc);
    for (parsed.lines) |line| {
        try source_lines.appendSlice(line.line);
        try source_lines.append('\n');
    }

    const formatted = if (Highlight.Language.guessFromFilename(blame_file)) |lang| fmt: {
        var pre = try Highlight.highlight(ctx.alloc, lang, source_lines.items);
        break :fmt pre[28..][0 .. pre.len - 38];
    } else verse.abx.Html.cleanAlloc(ctx.alloc, source_lines.items) catch return error.Unknown;

    var litr = std.mem.splitScalar(u8, formatted, '\n');
    for (parsed.lines) |*line| {
        if (litr.next()) |n| {
            line.line = n;
        } else {
            break;
        }
    }

    const wrapped_blames = try wrapLineNumbersBlame(ctx.alloc, parsed.lines, parsed.map, rd.name);
    //var btns = navButtons(ctx) catch return error.Unknown;

    var page = BlamePage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch return error.Unknown,
        .filename = verse.abx.Html.cleanAlloc(ctx.alloc, blame_file) catch unreachable,
        .blame_lines = wrapped_blames,
    });

    ctx.status = .ok;
    try ctx.sendPage(&page);
}

fn wrapLineNumbersBlame(
    a: Allocator,
    blames: []BlameLine,
    map: std.StringHashMap(BlameCommit),
    repo_name: []const u8,
) ![]S.BlameLines {
    const b_lines = try a.alloc(S.BlameLines, blames.len);
    for (blames, b_lines, 0..) |src, *dst, i| {
        const bcommit = map.get(src.sha) orelse unreachable;
        dst.* = .{
            .repo_name = repo_name,
            .sha = bcommit.sha[0..8],
            .author_email = .{
                .author = verse.abx.Html.cleanAlloc(a, bcommit.author.name) catch unreachable,
                .email = verse.abx.Html.cleanAlloc(a, bcommit.author.email) catch unreachable,
            },
            .time = try Humanize.unix(bcommit.author.timestamp).printAlloc(a),
            .num = i + 1,
            .line = src.line,
        };
    }
    return b_lines;
}

const BlameCommit = struct {
    sha: []const u8,
    parent: ?[]const u8 = null,
    title: []const u8,
    filename: []const u8,
    author: Git.Actor,
    committer: Git.Actor,
};

const BlameLine = struct {
    sha: []const u8,
    line: []const u8,
};

fn parseBlame(a: Allocator, blame_txt: []const u8) !struct {
    map: std.StringHashMap(BlameCommit),
    lines: []BlameLine,
} {
    var map = std.StringHashMap(BlameCommit).init(a);

    const count = std.mem.count(u8, blame_txt, "\n\t");
    const lines = try a.alloc(BlameLine, count);
    var in_lines = std.mem.splitScalar(u8, blame_txt, '\n');
    for (lines) |*blm| {
        const line = in_lines.next() orelse break;
        if (line.len < 40) unreachable;
        const gp = try map.getOrPut(line[0..40]);
        const cmt: *BlameCommit = gp.value_ptr;
        if (!gp.found_existing) {
            cmt.*.sha = line[0..40];
            cmt.*.parent = null;
            while (true) {
                const next = in_lines.next() orelse return error.UnexpectedEndOfBlame;
                if (next[0] == '\t') {
                    blm.*.line = next[1..];
                    break;
                }

                if (std.mem.startsWith(u8, next, "author ")) {
                    cmt.*.author.name = next["author ".len..];
                } else if (std.mem.startsWith(u8, next, "author-mail ")) {
                    cmt.*.author.email = next["author-mail ".len..];
                } else if (std.mem.startsWith(u8, next, "author-time ")) {
                    cmt.*.author.timestamp = try std.fmt.parseInt(i64, next["author-time ".len..], 10);
                } else if (std.mem.startsWith(u8, next, "author-tz ")) {
                    cmt.*.author.tz = try std.fmt.parseInt(i32, next["author-tz ".len..], 10);
                } else if (std.mem.startsWith(u8, next, "summary ")) {
                    cmt.*.title = next["summary ".len..];
                } else if (std.mem.startsWith(u8, next, "previous ")) {
                    cmt.*.parent = next["previous ".len..][0..40];
                } else if (std.mem.startsWith(u8, next, "filename ")) {
                    cmt.*.filename = next["filename ".len..];
                } else if (std.mem.startsWith(u8, next, "committer ")) {
                    cmt.*.committer.name = next["committer ".len..];
                } else if (std.mem.startsWith(u8, next, "committer-mail ")) {
                    cmt.*.committer.email = next["committer-mail ".len..];
                } else if (std.mem.startsWith(u8, next, "committer-time ")) {
                    cmt.*.committer.timestamp = try std.fmt.parseInt(i64, next["committer-time ".len..], 10);
                } else if (std.mem.startsWith(u8, next, "committer-tz ")) {
                    cmt.*.committer.tz = try std.fmt.parseInt(i32, next["committer-tz ".len..], 10);
                } else {
                    std.debug.print("unexpected blame data {s}\n", .{next});
                    continue;
                }
            }
        } else {
            blm.line = in_lines.next().?[1..];
        }
        blm.sha = cmt.*.sha;
    }

    return .{
        .map = map,
        .lines = lines,
    };
}

const tree = @import("tree.zig").tree;
const repos_ = @import("../repos.zig");
const RouteData = repos_.RouteData;

const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;

const verse = @import("verse");
const Humanize = @import("../../humanize.zig");
const Frame = verse.Frame;
const S = verse.template.Structs;
const PageData = verse.template.PageData;
const Router = verse.Router;
const repos = @import("../../repos.zig");
const Git = @import("../../git.zig");
const Highlight = @import("../../syntax-highlight.zig");
