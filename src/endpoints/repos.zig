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
    ROUTE("tags", tags.list),
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

    if (repo.tags) |rtags| {
        tag = .{
            .tag = rtags[0].name,
            .title = try allocPrint(a, "created {}", .{Humanize.unix(rtags[0].tagger.timestamp)}),
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
            std.sort.heap(Git.Tag, rpo.tags.?, {}, tags.sort);
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

    var page = ReposPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch return error.Unknown,

        .buttons = .{ .buttons = repo_buttons },
        .repo_list = repos_compiled,
    });

    try ctx.sendPage(&page);
}

const treeBlob = @import("repos/blob.zig").treeBlob;
const tree = @import("repos/tree.zig").tree;
const blame = @import("repos/blame.zig").blame;
const tags = @import("repos/tags.zig");

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
