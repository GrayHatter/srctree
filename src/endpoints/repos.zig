pub const verse_name = .repos;

pub const verse_aliases = .{
    .repo,
};

pub const verse_router = &router;

pub const verse_endpoints_ = verse.Endpoints(.{
    @import("repos/issues.zig"),
    @import("repos/diffs.zig"),
});

pub const routes = [_]Router.Match{
    ROUTE("blame", blame),
    ROUTE("blob", treeBlob),
    ROUTE("branches", branches.list),
    ROUTE("commit", &Commits.router),
    ROUTE("commits", &Commits.router),
    //ROUTE("diffs", &Diffs.router),
    ROUTE("ref", treeBlob),
    ROUTE("tags", tags.list),
    ROUTE("tree", treeBlob),
} ++ gitweb.endpoints ++ verse_endpoints_.routes;

pub const RouteData = struct {
    name: []const u8,
    verb: ?Verb = null,
    ref: ?[]const u8 = null,
    path: ?Path = null,

    const Path = std.mem.SplitIterator(u8, .scalar);

    pub const Verb = enum {
        branches,
        blame,
        blob,
        commit,
        commits,
        ref,
        tree,
        issue,
        issues,
        diff,
        diffs,
        tags,
        // gitweb endpoints
        info,
        objects,
        @"git-upload-pack",

        pub fn fromSlice(slice: ?[]const u8) ?Verb {
            const s = slice orelse return null;
            inline for (@typeInfo(Verb).@"enum".fields) |f| {
                if (eql(u8, s, f.name)) {
                    return @enumFromInt(f.value);
                }
            }
            return null;
        }
    };

    pub fn init(uri_itr: verse.Uri.Iterator) ?RouteData {
        var uri = uri_itr;
        uri.reset();
        _ = uri.next() orelse return null;
        const name = validRepoName(uri.next()) orelse return null;
        var verb: ?Verb = Verb.fromSlice(uri.next()) orelse return .{ .name = name };
        var ref: ?[]const u8 = null;
        var path: ?Path = null;
        switch (verb.?) {
            .commit => ref = uri.next() orelse return .{ .name = name },
            .ref => {
                ref = validRef(uri.next()) orelse return .{ .name = name };
                verb = if (uri.next()) |n| Verb.fromSlice(n) else null;
                path = .{ .index = 0, .buffer = uri.rest(), .delimiter = '/' };
            },
            else => path = .{ .index = 0, .buffer = uri.rest(), .delimiter = '/' },
        }
        return .{
            .name = name,
            .verb = verb,
            .ref = ref,
            .path = path,
        };
    }

    pub fn exists(self: RouteData) bool {
        return repos.exists(self.name, .public);
    }

    fn validRepoName(name: ?[]const u8) ?[]const u8 {
        if (name) |n| {
            // why 30? who knows
            if (n.len > 30) return null;
            for (n) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return null;
            if (std.mem.indexOf(u8, n, "..")) |_| return null;
            return n;
        }
        return null;
    }

    fn validRef(ref: ?[]const u8) ?[]const u8 {
        return ref;
    }
};

pub fn navButtons(f: *Frame) ![2]S.NavButtons {
    const rd = RouteData.init(f.uri) orelse return error.InvalidURI;
    if (!rd.exists()) return error.InvalidURI;
    var i_count: usize = 0;
    var d_count: usize = 0;
    var itr: Delta.Iterator = .init(rd.name, f.io);
    while (itr.next(f.alloc, f.io)) |dlt| {
        switch (dlt.attach) {
            .diff => d_count += 1,
            .issue => i_count += 1,
            else => {},
        }
        dlt.raze(f.alloc);
    }

    const btns = [2]S.NavButtons{
        .{
            .name = "issues",
            .extra = i_count,
            .url = try allocPrint(f.alloc, "/repo/{s}/issues/", .{rd.name}),
        },
        .{
            .name = "diffs",
            .extra = d_count,
            .url = try allocPrint(f.alloc, "/repo/{s}/diffs/", .{rd.name}),
        },
    };

    return btns;
}

pub const PatchView = struct {
    @"inline": ?bool = null,
};

pub fn getAndSavePatchView(f: *Frame) bool {
    const udata: PatchView = f.request.data.query.validate(PatchView) catch .{ .@"inline" = null };
    if (udata.@"inline") |inln| {
        f.cookie_jar.add(.{
            .name = "diff-inline",
            .value = if (inln) "1" else "0",
        }) catch {};
        return inln;
    } else {
        if (f.request.cookie_jar.get("diff-inline")) |cookie| {
            return (cookie.value.len > 0 and cookie.value[0] == '1');
        }
    }
    return true;
}

pub fn router(f: *Frame) Router.RoutingError!Router.BuildFn {
    const rd = RouteData.init(f.uri) orelse return list;

    if (rd.exists()) {
        const bh: *S.BodyHeaderHtml = if (f.response_data.get(S.BodyHeaderHtml)) |bhP| bhP else bhP: {
            f.response_data.clone(S.BodyHeaderHtml, f.alloc, .{ .nav = .{
                .nav_auth = "Error",
                .nav_buttons = undefined,
            } }) catch unreachable;
            break :bhP f.response_data.get(S.BodyHeaderHtml).?;
        };
        bh.nav.nav_buttons = f.alloc.dupe(S.NavButtons, &(navButtons(f) catch @panic("unreachable"))) catch unreachable;

        _ = f.uri.next();
        _ = f.uri.next();

        if (rd.verb) |verb| {
            return switch (verb) {
                inline else => |v| Router.targetRouter(f, @tagName(v), &routes),
            };
        }
        return treeBlob;
        //return Router.defaultRouter(f, &routes);
    }
    return error.Unrouteable;
}

const repoctx = struct {
    alloc: Allocator,
    io: Io,
    by: enum {
        commit,
        tag,
    } = .commit,
};

fn repoSorterNew(ctx: repoctx, l: Git.Repo, r: Git.Repo) bool {
    return !repoSorter(ctx, l, r);
}

fn commitSorter(ctx: repoctx, l: Git.Repo, r: Git.Repo) bool {
    var lc = l.headCommit(ctx.alloc, ctx.io) catch return true;
    defer lc.raze();
    var rc = r.headCommit(ctx.alloc, ctx.io) catch return false;
    defer rc.raze();
    return sorter({}, lc.committer.timestr, rc.committer.timestr);
}

fn sortPinned(l: Git.Repo, r: Git.Repo) ?bool {
    const left_pinned: bool = if (l.config) |cfg|
        if (cfg.ctx.get("srctree")) |srctree|
            srctree.getBool("pinned") orelse false
        else
            false
    else
        false;

    const right_pinned: bool = if (r.config) |cfg|
        if (cfg.ctx.get("srctree")) |srctree|
            srctree.getBool("pinned") orelse false
        else
            false
    else
        false;

    if (left_pinned == right_pinned) {
        return null;
    } else if (left_pinned) {
        return true;
    } else if (right_pinned) {
        return false;
    }
    return null;
}

// TODO deep invert this logic
fn repoSorter(ctx: repoctx, l: Git.Repo, r: Git.Repo) bool {
    if (sortPinned(l, r)) |pinned| return !pinned;

    switch (ctx.by) {
        .commit => {
            return commitSorter(ctx, l, r);
        },
        .tag => {
            if (l.tags) |lt| {
                if (r.tags) |rt| {
                    if (lt.len == 0) return true;
                    if (rt.len == 0) return false;
                    if (lt[0].tagger.timestamp == rt[0].tagger.timestamp)
                        return commitSorter(ctx, l, r);
                    return lt[0].tagger.timestamp > rt[0].tagger.timestamp;
                } else return false;
            } else return true;
        },
    }
}

fn sorter(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

fn repoBlock(name: []const u8, repo: Git.Repo, a: Allocator, io: Io) !S.ReposHtml.RepoList {
    const now = (Io.Clock.now(.real, io) catch unreachable).toSeconds();
    var desc: ?[]const u8 = try repo.description(a, io);
    if (std.mem.startsWith(u8, desc.?, "Unnamed repository; edit this file")) {
        desc = null;
    }

    var upstream: ?[]const u8 = null;
    if (repo.findRemote("upstream")) |remote| {
        upstream = try allocPrint(a, "{f}", .{std.fmt.alt(remote, .formatLink)});
    }
    var updated: []const u8 = "new repo";
    if (repo.headCommit(a, io)) |cmt| {
        defer cmt.raze();
        const committer = cmt.committer;
        updated = try allocPrint(
            a,
            "updated about {f}",
            .{Humanize.unix(committer.timestamp, now)},
        );
    } else |_| {}

    var tag: ?S.ReposHtml.RepoList.Tag = null;

    if (repo.tags) |rtags| {
        tag = .{
            .tag = try a.dupe(u8, rtags[0].name),
            .title = try allocPrint(a, "created {f}", .{Humanize.unix(rtags[0].tagger.timestamp, now)}),
            .uri = try allocPrint(a, "/repo/{s}/tags", .{name}),
        };
    }

    return .{
        .name = name,
        .uri = try allocPrint(a, "/repo/{s}", .{name}),
        .desc = desc,
        .upstream_blk = if (upstream) |u| .{ .link = u } else null,
        .updated = updated,
        .tag = tag,
    };
}

const ReposPage = PageData("repos.html");

const RepoSortReq = struct {
    sort: ?[]const u8,
};

fn list(f: *Frame) Router.Error!void {
    const udata = f.request.data.query.validate(RepoSortReq) catch return error.DataInvalid;
    const tag_sort: bool = if (udata.sort) |srt| if (eql(u8, srt, "tag")) true else false else false;

    var repo_iter = repos.allRepoIterator(.public) catch return error.Unknown;
    var current_repos: ArrayList(Git.Repo) = .{};
    while (repo_iter.next(f.io) catch return error.Unknown) |rpo_| {
        var rpo = rpo_;
        rpo.loadData(f.alloc, f.io) catch |err| {
            log.err("Error, unable to load data on repo {s} {}", .{ repo_iter.current_name.?, err });
            continue;
        };
        rpo.repo_name = f.alloc.dupe(u8, repo_iter.current_name.?) catch null;

        if (rpo.tags != null) {
            std.sort.heap(Git.Tag, rpo.tags.?, {}, tags.sort);
        }
        try current_repos.append(f.alloc, rpo);
    }

    std.sort.heap(Git.Repo, current_repos.items, repoctx{
        .alloc = f.alloc,
        .io = f.io,
        .by = if (tag_sort) .tag else .commit,
    }, repoSorterNew);

    var repo_buttons: ?[]const u8 = null;
    if (f.user != null and f.user.?.valid()) {
        repo_buttons =
            \\<div class="act-btns"><a class="btn" href="/admin/clone-upstream">New Upstream</a></div>
        ;
    }

    const repos_compiled = try f.alloc.alloc(S.ReposHtml.RepoList, current_repos.items.len);
    for (current_repos.items, repos_compiled) |*repo, *compiled| {
        defer repo.raze(f.alloc, f.io);
        compiled.* = repoBlock(repo.repo_name orelse "unknown", repo.*, f.alloc, f.io) catch {
            return error.Unknown;
        };
    }

    var page = ReposPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = f.response_data.get(S.BodyHeaderHtml).?.*,
        .buttons = repo_buttons,
        .repo_list = repos_compiled,
    });

    try f.sendPage(&page);
}

const treeBlob = @import("repos/blob.zig").treeBlob;
const tree = @import("repos/tree.zig").tree;
const blame = @import("repos/blame.zig").blame;
const tags = @import("repos/tags.zig");
const branches = @import("repos/branches.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const allocPrint = std.fmt.allocPrint;
const eql = std.mem.eql;
const log = std.log.scoped(.srctree);

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

const Delta = @import("../types.zig").Delta;

const gitweb = @import("../gitweb.zig");
