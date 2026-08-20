pub const verse_name = .repos;
pub const verse_aliases = .{.repo};
pub const verse_router = &router;

pub const verse_endpoints_ = verse.Endpoints(.{
    @import("repos/issues.zig"),
    @import("repos/diffs.zig"),
    @import("repos/search.zig"),
    @import("repos/artifacts.zig"),
    @import("repos/hook.zig"),
});

pub const routes = [_]verse.Router.Match{
    ROUTE("blame", blame),
    ROUTE("blob", treeBlob),
    ROUTE("branches", branches.list),
    ROUTE("commit", &Commits.router),
    ROUTE("commits", &Commits.router),
    //ROUTE("diffs", &Diffs.router),
    ROUTE("ref", treeBlob),
    ROUTE("tags", tags.list),
    ROUTE("tree", treeBlob),
} ++
    gitweb.endpoints ++
    verse_endpoints_.routes;

/// Deprecated in favor of `RepoRouter`.
pub const RouteData = Router;

pub const Router = struct {
    name: []const u8,
    verb: ?Verb = null,
    ref: ?[]const u8 = null,
    path: ?Path = null,

    const Path = verse.Uri;

    // TODO delete me
    pub const RoutingError = verse.Router.RoutingError;

    pub const Verb = enum {
        /// srctree endpoints
        artifacts,
        diff,
        diffs,
        docs,
        hook,
        issue,
        issues,
        search,

        /// git core endpoints
        blame,
        blob,
        branches,
        commit,
        commits,
        ref,
        tags,
        tree,

        // gitweb endpoints
        info,
        objects, // TODO objects may only need to exist for dumb clients.
        @"git-upload-pack",
        @"git-receive-pack",

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

    pub fn init(frame: *const Frame) ?Router {
        var uri = frame.uri;
        uri.index = 0;
        _ = uri.next() orelse return null; // route
        const name = validRepoName(uri.next()) orelse return null;
        const verb: Verb = Verb.fromSlice(uri.next()) orelse return .{ .name = name };
        return switch (verb) {
            .commit => .{
                .name = name,
                .ref = uri.next(),
                .verb = verb,
                .path = null,
            },
            .ref => .{
                .name = name,
                .ref = validRef(uri.next()),
                .verb = if (uri.next()) |n| Verb.fromSlice(n) else null,
                .path = if (uri.withoutPrefix()) |wo| Path.init(wo) catch null else null,
            },
            else => .{
                .name = name,
                .ref = null,
                .verb = verb,
                .path = if (uri.withoutPrefix()) |wo| Path.init(wo) catch null else null,
            },
        };
    }

    pub fn exists(self: Router, vis: Repo.Visibility.Select, io: Io) bool {
        return Repo.exists(self.name, vis, io);
    }

    fn mkNav(name: []const u8, i: usize, d: usize, a: Allocator) [2]S.NavButtons {
        return .{
            .{ .name = .safe("issues"), .extra = i, .url = .abx(
                allocPrint(a, "/repo/{s}/issues/", .{name}) catch "[OOM]",
            ) },
            .{ .name = .safe("diffs"), .extra = d, .url = .abx(
                allocPrint(a, "/repo/{s}/diffs/", .{name}) catch "[OOM]",
            ) },
        };
    }

    pub fn navButtons(rd: RouteData, f: *Frame) [2]S.NavButtons {
        const vis: Repo.Visibility.Select = if (f.user) |_| .all else .public_only;
        if (!rd.exists(vis, f.io)) return mkNav(rd.name, 0, 0, f.alloc);
        var i_count: usize = 0;
        var d_count: usize = 0;
        var itr: Delta.RepoIterator = .init(rd.name, f.io);
        while (itr.next(f.alloc, f.io)) |dlt| {
            defer dlt.raze(f.alloc);
            if (!dlt.state.isOpen()) continue;
            switch (dlt.attach) {
                .diff => d_count += 1,
                .issue => i_count += 1,
                else => {},
            }
        }

        const btns = [2]S.NavButtons{
            .{
                .name = .safe("issues"),
                .extra = i_count,
                .url = .safe(allocPrint(f.alloc, "/repo/{s}/issues/", .{rd.name}) catch "[OOM]"),
            },
            .{
                .name = .safe("diffs"),
                .extra = d_count,
                .url = .safe(allocPrint(f.alloc, "/repo/{s}/diffs/", .{rd.name}) catch "[OOM]"),
            },
        };

        return btns;
    }

    pub fn repoHeader(rd: Router, host: []const u8) !S.BaseRepoHeaderHtml {
        _ = rd;
        _ = host;
        unreachable;
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

pub const PatchView = struct {
    @"inline": ?bool = null,
};

pub const PatchViewMode = enum {
    inlined,
    split,
};

pub fn updatePatchView(f: *Frame) ?PatchViewMode {
    if (f.request.data.query.validate(PatchView)) |data| {
        if (data.@"inline") |inln| {
            f.cookie_jar.add(.{
                .name = "diff-inline",
                .value = if (inln) "1" else "0",
            }) catch {};
            return if (inln) .inlined else .split;
        }
    } else |_| {}
    return null;
}

/// or error when unknown
pub fn updateFetchPatchView(f: *Frame) error{Unspecified}!PatchViewMode {
    if (updatePatchView(f)) |q| {
        return q;
    } else if (f.request.cookie_jar.get("diff-inline")) |cookie| {
        return if (cookie.value.len > 0 and cookie.value[0] == '1')
            .inlined
        else
            .split;
    }

    return error.Unspecified;
}

fn useGitProto(f: *const Frame) bool {
    const rd = RouteData.init(f) orelse return false;
    if (rd.ref) |_| return false;
    if (f.request.user_agent) |ua| switch (ua.agent) {
        .script => |script| return script.name == .git or script.name == .zig,
        .bot => {},
        .browser => {},
        .unknown => {},
    };
    return false;
}

pub fn router(f: *Frame) Router.RoutingError!verse.Router.BuildFn {
    const rd = RouteData.init(f) orelse return list;

    const vis: Repo.Visibility.Select = if (f.user) |_| .all else .public_only;
    if (rd.exists(vis, f.io)) {
        if (useGitProto(f)) return gitweb.router(f);

        if (Repo.openGit(rd.name, vis, f.io)) |repo_| b: {
            var repo = repo_ orelse break :b;
            if (repo.loadData(f.alloc, f.io)) {
                defer repo.raze(f.alloc, f.io);
                if (repo.findRemote("upstream")) |_| {
                    if (repo.config.?.srctree) |s| if (s.pinned) |p| if (p) break :b;
                    f.response_headers.addCustom(f.alloc, "X-Robots-Tag", "none") catch {};
                }
            } else |_| {}
        } else |_| {}
        const bh: *S.BodyHeaderHtml = if (f.response_data.get(S.BodyHeaderHtml)) |bhP| bhP else bhP: {
            f.response_data.clone(S.BodyHeaderHtml, f.alloc, .{ .nav = .{
                .nav_auth = "Error",
                .nav_buttons = undefined,
            } }) catch unreachable;
            break :bhP f.response_data.get(S.BodyHeaderHtml).?;
        };
        bh.nav.nav_buttons = f.alloc.dupe(S.NavButtons, &(rd.navButtons(f))) catch @panic("OOM");

        _ = f.uri.next();
        _ = f.uri.next();

        if (rd.verb) |verb| {
            return switch (verb) {
                inline else => |v| verse.Router.targetRouter(f, @tagName(v), &routes),
            };
        }
        return treeBlob;
        //return Router.defaultRouter(f, &routes);
    } else if (useGitProto(f)) {
        return gitweb.router(f);
    }

    return error.Unrouteable;
}

fn sorter(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

fn svgPoints(repo: *const Repo, arena: Allocator, io: Io) !abx.Html {
    const width = 52 * "l 100 100 ".len;
    const b = try arena.alloc(u8, width);
    errdefer arena.free(b);
    var w: Writer = .fixed(b);

    var now: Io.Timestamp = .now(io, .real);
    var heat: [52]u16 = @splat(0);

    var max: isize = 1;
    var commit: Git.Commit = repo.git.HEAD(arena, io) catch return .safe("V 46 M 109 46 ");

    for (0..52) |i| {
        const r_idx = heat.len - 1 - i;
        const first = now.addDuration(.fromSeconds(-86400 * 7));
        defer now = first;
        const week: *u16 = &heat[r_idx];
        while (commit.committer.timestamp > first.toSeconds()) {
            commit = commit.toParent(0, &repo.git, arena, io) catch break;
            week.* +|= 1;
        }
        max = @max(max, week.*);
    }

    var hob: isize = 0;
    for (heat) |week| {
        const adjst: isize = @divTrunc(41 * @as(isize, @intCast(week)), max);
        if (hob - adjst != 0)
            w.print("l 2 {} ", .{0 + hob - adjst}) catch unreachable
        else
            w.writeAll("h 2 ") catch unreachable;
        hob = adjst;
    }
    return .safe(w.buffered());
}

fn repoBlock(name: []const u8, repo: *Repo, a: Allocator, io: Io) !S.ReposHtml.RepoList {
    const now = Io.Clock.real.now(io).toSeconds();
    const desc: []const u8 = try allocPrint(a, "{f}", .{
        abx.Html{ .text = repo.git.description(a, io) catch "" },
    });

    var upstream: ?[]const u8 = null;
    if (repo.git.findRemote("upstream")) |remote| {
        upstream = try allocPrint(a, "{f}", .{std.fmt.alt(remote, .formatLink)});
    }

    var sha: Git.Sha = .zeros;
    var updated: []const u8 = "new repo";
    if (repo.git.HEAD(a, io)) |cmt| {
        defer cmt.raze(a);
        sha = cmt.sha;
        const committer = cmt.committer;
        updated = try allocPrint(a, "{f}", .{Humanize.unix(committer.timestamp, now)});
    } else |_| {}

    var tag_list: std.ArrayList(Git.Tag) = .empty;
    for (repo.git.refs.map.keys(), repo.git.refs.map.values()) |tag_name, ref| switch (ref) {
        .tag => tag_list.append(a, Git.Tag.fromObject(
            repo.git.objects.load(ref.resolve(&repo.git) catch continue, a, io) catch continue,
            a.dupe(u8, tag_name) catch unreachable,
        ) catch continue) catch unreachable,
        else => {},
    };

    Git.Tag.sort(&tag_list);

    var tag: ?S.ReposHtml.RepoList.TagBlk = null;
    if (tag_list.items.len > 0) {
        tag = .{
            .tag = .abx(try a.dupe(u8, tag_list.items[0].name)),
            .updated = .safe(
                try allocPrint(a, "tagged {f}", .{Humanize.unix(tag_list.items[0].tagger.timestamp, now)}),
            ),
        };
    }

    var repo_class: ?[]const u8 = "lowlight";
    if (repo.git.config) |cfg| {
        if (cfg.srctree) |srctree| {
            if (srctree.pinned orelse false) repo_class = null;
        }
    }
    const status = repo.ci.status(a, io) catch unreachable;
    std.debug.print("repo.ci {s} = {any}\n", .{ name, repo.ci.srctree });

    const commit_uri = try allocPrint(a, "/repo/{s}/commit/{f}", .{ name, std.fmt.alt(sha, .fmtHex) });
    const sha_str = try sha.text().dupe(a);
    return .{
        .name = .abx(name),
        .repo_class = repo_class,
        .commit_uri = .safe(commit_uri),
        .sha = .safe(sha_str),
        .sha_short = .safe(sha_str[0..10]),
        .uri = .safe(commit_uri[0 .. 6 + name.len]),
        .desc = desc,
        .upstream_blk = if (upstream) |u| .{ .link = .safe(u) } else null,
        .updated = .safe(updated),
        .tag_blk = tag,
        .svg_points = try svgPoints(repo, a, io),
        .ci_status = if (status) .broken else .disabled,
    };
}

const ReposPage = PageData("repos.html");

const RepoSortReq = struct {
    sort: ?[]const u8,
};

fn list(f: *Frame) verse.Router.Error!void {
    const udata = f.request.data.query.validate(RepoSortReq) catch return error.DataInvalid;
    const tag_sort: bool = if (udata.sort) |srt| if (eql(u8, srt, "tag")) true else false else false;

    const vis: Repo.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo_iter = Repo.allRepoIterator(vis, f.io) catch return error.Unknown;
    var current_repos: ArrayList(Repo) = .empty;
    while (repo_iter.next(f.io) catch return error.Unknown) |rpo_| {
        var rpo = rpo_;
        rpo.git.loadData(f.alloc, f.io) catch |err| {
            log.err("Error, unable to load data on repo {s} {}", .{ repo_iter.current_name.?, err });
            continue;
        };
        rpo.name = f.alloc.dupe(u8, repo_iter.current_name.?) catch null;

        try current_repos.append(f.alloc, rpo);
    }

    Repo.Sort.sort(&current_repos, f.alloc, f.io, if (tag_sort) .tag else .commit);

    const repos_compiled = try f.alloc.alloc(S.ReposHtml.RepoList, current_repos.items.len);
    for (current_repos.items, repos_compiled) |*repo, *compiled| {
        defer repo.raze(f.alloc, f.io);
        compiled.* = repoBlock(repo.name orelse "unknown", repo, f.alloc, f.io) catch {
            return error.Unknown;
        };
    }

    const repo_buttons: ?[]const u8 = if (f.user != null and f.user.?.valid())
        \\<div class="act-btns"><a class="btn" href="/admin/repo/clone">New Upstream Repo</a></div>
        \\<div class="act-btns"><a class="btn" href="/admin/repo/create">New Empty Repo</a></div>
    else
        null;

    var page = ReposPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = f.response_data.get(S.BodyHeaderHtml).?.*,
        .count = repos_compiled.len,
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
const Writer = Io.Writer;
const allocPrint = std.fmt.allocPrint;
const eql = std.mem.eql;
const log = std.log.scoped(.srctree);

const verse = @import("verse");
const abx = verse.Antibiotic;
const Frame = verse.Frame;
const PageData = verse.template.PageData;
const html = verse.template.html;
const S = verse.template.Structs;
const ROUTE = verse.Router.ROUTE;
const Humanize = @import("../humanize.zig");
const Repo = @import("../Repo.zig");
const Git = @import("../git.zig");
const Highlight = @import("../syntax-highlight.zig");
const Commits = @import("repos/commits.zig");
const Diffs = @import("repos/diffs.zig");

const Delta = @import("../types.zig").Delta;

const gitweb = @import("../gitweb.zig");
