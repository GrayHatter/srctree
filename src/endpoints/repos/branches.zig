const BranchPage = PageData("branches.html");

pub fn list(frame: *Frame) Router.Error!void {
    const rd = RouteData.init(frame.uri) orelse return error.Unrouteable;

    const vis: repos.Visibility.Select = if (frame.user) |_| .all else .public_only;
    var repo = (repos.open(rd.name, vis, frame.io) catch return error.Unknown) orelse return error.InvalidURI;
    repo.loadData(frame.alloc, frame.io) catch return error.Unknown;
    defer repo.raze(frame.alloc, frame.io);

    // leaks a lot
    var all_branches: std.ArrayList(Git.Branch) = .empty;
    try all_branches.appendSlice(frame.alloc, repo.branches orelse return error.InvalidURI);
    if (repo.loadBranchesFrom("refs/remotes/upstream", frame.alloc, frame.io)) |upstream| {
        try all_branches.appendSlice(frame.alloc, upstream);
    } else |err| switch (err) {
        error.BranchRefMissing => {},
        else => log.err("unable to load upstream branches {}", .{err}),
    }
    const repo_branches = try all_branches.toOwnedSlice(frame.alloc);

    std.sort.heap(Git.Branch, repo_branches, SortCtx.init(&repo, frame.alloc, frame.io), sort);

    const branches: []S.BranchesHtml.RepoBranches = try frame.alloc.alloc(S.BranchesHtml.RepoBranches, repo_branches.len);
    for (repo_branches, branches) |branch, *html| {
        html.* = .{
            .name = .abx(branch.name),
            .sha = .safe(try branch.sha.textAlloc(frame.alloc)),
        };
    }

    const upstream: ?S.BaseRepoHeaderHtml.Upstream = if (repo.findRemote("upstream")) |up| .{
        .href = .safe(try allocPrint(frame.alloc, "{f}", .{std.fmt.alt(up, .formatLink)})),
    } else null;

    const open_graph: S.OpenGraph = .{
        .title = rd.name,
        .desc = try allocPrint(frame.alloc, "{} branches", .{branches.len}),
    };

    var page = BranchPage.init(.{
        .meta_head = .{ .open_graph = open_graph },
        .body_header = frame.response_data.get(S.BodyHeaderHtml).?.*,
        .repo_header = .{
            .repo_name = .abx(rd.name),
            .description = .abx(try frame.alloc.dupe(u8, repo.description(frame.alloc, frame.io) catch "")),
            .blame = null,
            .git_uri = null,
            .upstream = upstream,
        },
        .repo_branches = branches,
    });

    try frame.sendPage(&page);
}

const SortCtx = struct {
    repo: *const Git.Repo,
    a: Allocator,
    io: Io,

    pub fn init(r: *const Git.Repo, a: Allocator, io: Io) SortCtx {
        return .{ .repo = r, .a = a, .io = io };
    }
};

pub fn sort(ctx: SortCtx, l: Git.Branch, r: Git.Branch) bool {
    const lc: Git.Commit = l.toCommit(ctx.repo, ctx.a, ctx.io) catch return false;
    const rc: Git.Commit = r.toCommit(ctx.repo, ctx.a, ctx.io) catch return false;
    const ltime = lc.committer.timestamp;
    const rtime = rc.committer.timestamp;
    if (ltime == rtime) return (l.name.len < r.name.len);
    return ltime > rtime;
}

const repos = @import("../../repos.zig");
const RouteData = @import("../repos.zig").RouteData;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const allocPrint = std.fmt.allocPrint;
const verse = @import("verse");
const T = verse.template;
const S = verse.template.Structs;
const abx = verse.abx;
const Frame = verse.Frame;
const PageData = verse.template.PageData;
const Router = verse.Router;
const Git = @import("../../git.zig");
const log = std.log.scoped(.srctree_branches);
