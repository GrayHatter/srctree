pub const verse_name = .repos;

pub const verse_alias = .{
    .repo,
};

pub const verse_router = &router;

pub const routes = [_]Router.Match{
    ROUTE("blame", blame),
    ROUTE("blob", treeBlob),
    ROUTE("commit", &Commits.router),
    ROUTE("commits", &Commits.router),
    ROUTE("diffs", &Diffs.router),
    ROUTE("issues", &Issues.router),
    ROUTE("tags", tagsList),
    ROUTE("tree", treeBlob),
} ++ gitweb.endpoints;

pub const RouteData = struct {
    name: []const u8,
    verb: ?[]const u8 = null,
    noun: ?[]const u8 = null,

    fn safe(name: ?[]const u8) ?[]const u8 {
        if (name) |n| {
            // why 30? who knows
            if (n.len > 30) return null;
            for (n) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return null;
            if (std.mem.indexOf(u8, n, "..")) |_| return null;
            return n;
        }
        return null;
    }

    pub fn make(uri: *Router.UriIterator) ?RouteData {
        const idx = uri.index;
        defer uri.index = idx;
        uri.reset();
        _ = uri.next() orelse return null;
        return .{
            .name = safe(uri.next()) orelse return null,
            .verb = uri.next(),
            .noun = uri.next(),
        };
    }

    pub fn exists(self: RouteData) bool {
        return repos.exists(self.name, .public);
    }
};

pub fn navButtons(ctx: *Frame) ![2]S.NavButtons {
    const rd = RouteData.make(&ctx.uri) orelse unreachable;
    if (!rd.exists()) unreachable;
    var i_count: usize = 0;
    var d_count: usize = 0;
    var itr = Delta.iterator(ctx.alloc, rd.name);
    while (itr.next()) |dlt| {
        switch (dlt.attach) {
            .diff => d_count += 1,
            .issue => i_count += 1,
            else => {},
        }
        dlt.raze(ctx.alloc);
    }

    const btns = [2]S.NavButtons{
        .{
            .name = "issues",
            .extra = i_count,
            .url = try allocPrint(ctx.alloc, "/repos/{s}/issues/", .{rd.name}),
        },
        .{
            .name = "diffs",
            .extra = d_count,
            .url = try allocPrint(ctx.alloc, "/repos/{s}/diffs/", .{rd.name}),
        },
    };

    return btns;
}

pub fn router(ctx: *Frame) Router.RoutingError!Router.BuildFn {
    const rd = RouteData.make(&ctx.uri) orelse return list;

    if (rd.exists()) {
        var bh: S.BodyHeaderHtml = ctx.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{
            .nav_auth = "Error",
            .nav_buttons = undefined,
        } };
        bh.nav.nav_buttons = ctx.alloc.dupe(S.NavButtons, &(navButtons(ctx) catch @panic("unreachable"))) catch unreachable;
        ctx.response_data.add(bh) catch unreachable;

        if (rd.verb) |_| {
            _ = ctx.uri.next();
            _ = ctx.uri.next();
            return Router.defaultRouter(ctx, &routes);
        } else return treeBlob;
    }
    return error.Unrouteable;
}

const repoctx = struct {
    alloc: Allocator,
    by: enum {
        commit,
        tag,
    } = .commit,
};

fn tagSorter(_: void, l: Git.Tag, r: Git.Tag) bool {
    return l.tagger.timestamp >= r.tagger.timestamp;
}

fn repoSorterNew(ctx: repoctx, l: Git.Repo, r: Git.Repo) bool {
    return !repoSorter(ctx, l, r);
}

fn commitSorter(a: Allocator, l: Git.Repo, r: Git.Repo) bool {
    var lc = l.headCommit(a) catch return true;
    defer lc.raze();
    var rc = r.headCommit(a) catch return false;
    defer rc.raze();
    return sorter({}, lc.committer.timestr, rc.committer.timestr);
}

fn repoSorter(ctx: repoctx, l: Git.Repo, r: Git.Repo) bool {
    switch (ctx.by) {
        .commit => {
            return commitSorter(ctx.alloc, l, r);
        },
        .tag => {
            if (l.tags) |lt| {
                if (r.tags) |rt| {
                    if (lt.len == 0) return true;
                    if (rt.len == 0) return false;
                    if (lt[0].tagger.timestamp == rt[0].tagger.timestamp)
                        return commitSorter(ctx.alloc, l, r);
                    return lt[0].tagger.timestamp > rt[0].tagger.timestamp;
                } else return false;
            } else return true;
        },
    }
}

fn sorter(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

fn repoBlock(a: Allocator, name: []const u8, repo: Git.Repo) !S.RepoList {
    var desc: ?[]const u8 = try repo.description(a);
    if (std.mem.startsWith(u8, desc.?, "Unnamed repository; edit this file")) {
        desc = null;
    }

    var upstream: ?[]const u8 = null;
    if (try repo.findRemote("upstream")) |remote| {
        upstream = try allocPrint(a, "{link}", .{remote});
    }
    var updated: []const u8 = "new repo";
    if (repo.headCommit(a)) |cmt| {
        defer cmt.raze();
        const committer = cmt.committer;
        updated = try allocPrint(
            a,
            "updated about {}",
            .{Humanize.unix(committer.timestamp)},
        );
    } else |_| {}

    var tag: ?S.Tag = null;

    if (repo.tags) |tags| {
        tag = .{
            .tag = tags[0].name,
            .title = try allocPrint(a, "created {}", .{Humanize.unix(tags[0].tagger.timestamp)}),
            .uri = try allocPrint(a, "/repo/{s}/tags", .{name}),
        };
    }

    return .{
        .name = name,
        .uri = try allocPrint(a, "/repo/{s}", .{name}),
        .desc = desc,
        .upstream = upstream,
        .updated = updated,
        .tag = tag,
    };
}

const ReposPage = PageData("repos.html");

const RepoSortReq = struct {
    sort: ?[]const u8,
};

fn list(ctx: *Frame) Router.Error!void {
    const udata = ctx.request.data.query.validate(RepoSortReq) catch return error.BadData;
    const tag_sort: bool = if (udata.sort) |srt| if (eql(u8, srt, "tag")) true else false else false;

    var repo_iter = repos.allRepoIterator(.public) catch return error.Unknown;
    var current_repos = std.ArrayList(Git.Repo).init(ctx.alloc);
    while (repo_iter.next() catch return error.Unknown) |rpo_| {
        var rpo = rpo_;
        rpo.loadData(ctx.alloc) catch return error.Unknown;
        rpo.repo_name = ctx.alloc.dupe(u8, repo_iter.current_name.?) catch null;

        if (rpo.tags != null) {
            std.sort.heap(Git.Tag, rpo.tags.?, {}, tagSorter);
        }
        try current_repos.append(rpo);
    }

    std.sort.heap(Git.Repo, current_repos.items, repoctx{
        .alloc = ctx.alloc,
        .by = if (tag_sort) .tag else .commit,
    }, repoSorterNew);

    var repo_buttons: []const u8 = "";
    if (ctx.user != null and ctx.user.?.valid()) {
        repo_buttons =
            \\<div class="act-btns"><a class="btn" href="/admin/clone-upstream">New Upstream</a></div>
        ;
    }

    const repos_compiled = try ctx.alloc.alloc(S.RepoList, current_repos.items.len);
    for (current_repos.items, repos_compiled) |*repo, *compiled| {
        defer repo.raze();
        compiled.* = repoBlock(ctx.alloc, repo.repo_name orelse "unknown", repo.*) catch {
            return error.Unknown;
        };
    }

    //var btns = [1]template.Structs.NavButtons{.{
    //    .name = "inbox",
    //    .extra = 0,
    //    .url = "/inbox",
    //}};

    var page = ReposPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch return error.Unknown,

        .buttons = .{ .buttons = repo_buttons },
        .repo_list = repos_compiled,
    });

    try ctx.sendPage(&page);
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

const BlamePage = PageData("blame.html");

fn blame(ctx: *Frame) Router.Error!void {
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

const TreePage = PageData("tree.html");

const TagPage = PageData("repo-tags.html");

fn tagsList(ctx: *Frame) Router.Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;

    var repo = (repos.open(rd.name, .public) catch return error.Unknown) orelse return error.Unrouteable;
    repo.loadData(ctx.alloc) catch return error.Unknown;
    defer repo.raze();

    std.sort.heap(Git.Tag, repo.tags.?, {}, tagSorter);

    const tstack = try ctx.alloc.alloc(S.Tags, repo.tags.?.len);

    for (repo.tags.?, tstack) |tag, *html_| {
        html_.name = tag.name;
    }

    //var btns = navButtons(ctx) catch return error.Unknown;
    var page = TagPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch return error.Unknown,
        .upstream = null,
        .tags = tstack,
    });

    try ctx.sendPage(&page);
}

const treeBlob = @import("repos/blob.zig").treeBlob;
const tree = @import("repos/tree.zig").tree;

const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const eql = std.mem.eql;

const verse = @import("verse");
const Frame = verse.Frame;
const Router = verse.Router;
const PageData = verse.template.PageData;
const html = verse.template.html;
const S = verse.template.Structs;
const ROUTE = Router.ROUTE;
const Humanize = @import("../humanize.zig");
const repos = @import("../repos.zig");
const Git = @import("../git.zig");
const Highlight = @import("../syntax-highlight.zig");
const Commits = @import("repos/commits.zig");
const Diffs = @import("repos/diffs.zig");
const Issues = @import("repos/issues.zig");

const Delta = @import("../types.zig").Delta;

const gitweb = @import("../gitweb.zig");
