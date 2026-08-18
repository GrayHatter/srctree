const BranchPage = PageData("branches.html");

pub fn list(f: *Frame) Router.Error!void {
    const rd = RouteData.init(f) orelse return error.ServerFault;

    const vis: Repo.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo = (Repo.openGit(rd.name, vis, f.io) catch return error.Unknown) orelse return error.InvalidURI;
    repo.loadData(f.alloc, f.io) catch return error.Unknown;
    defer repo.raze(f.alloc, f.io);

    // leaks a lot
    var all_branches: std.ArrayList(Git.Branch) = .empty;
    for (repo.refs.map.keys(), repo.refs.map.values()) |name, branch| {
        switch (branch) {
            .sha => try all_branches.append(f.alloc, .{ .name = name, .sha = branch.sha }),
            .heads => try all_branches.append(f.alloc, .{ .name = name, .sha = branch.sha }),
            .ref => {},
            .tag => {},
            .diff => {},
            .remote => {},
        }
    }
    //if (repo.loadBranchesFrom("refs/remotes/upstream", f.alloc, f.io)) |upstream| {
    //    try all_branches.appendSlice(f.alloc, upstream);
    //} else |err| switch (err) {
    //    error.BranchRefMissing => {},
    //    else => log.err("unable to load upstream branches {}", .{err}),
    //}
    const repo_branches = try all_branches.toOwnedSlice(f.alloc);

    std.sort.heap(Git.Branch, repo_branches, SortCtx.init(&repo, f.alloc, f.io), sort);

    const branches: []S.BranchesHtml.RepoBranches = try f.alloc.alloc(
        S.BranchesHtml.RepoBranches,
        repo_branches.len,
    );
    for (repo_branches, branches) |branch, *html| {
        html.* = .{
            .name = .abx(branch.name),
            .sha = .safe(try branch.sha.textAlloc(f.alloc)),
        };
    }

    const upstream: ?S.BaseRepoHeaderHtml.Upstream = if (repo.findRemote("upstream")) |up| .{
        .href = .safe(try allocPrint(f.alloc, "{f}", .{std.fmt.alt(up, .formatLink)})),
    } else null;

    const open_graph: S.OpenGraph = .{
        .title = rd.name,
        .desc = try allocPrint(f.alloc, "{} branches", .{branches.len}),
    };

    var page = BranchPage.init(.{
        .meta_head = .{ .open_graph = open_graph },
        .body_header = f.response_data.get(S.BodyHeaderHtml).?.*,
        .repo_header = .{
            .repo_name = .abx(rd.name),
            .description = .abx(try f.alloc.dupe(u8, repo.description(f.alloc, f.io) catch "")),
            .blame = null,
            .git_uri = .{ .host = .safe(try f.request.host.?.valid()), .repo_name = .abx(rd.name) },
            .upstream = upstream,
        },
        .repo_branches = branches,
    });

    try f.sendPage(&page);
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

const RouteData = @import("../repos.zig").RouteData;
const Repo = @import("../../Repo.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const allocPrint = std.fmt.allocPrint;
const verse = @import("verse");
const T = verse.template;
const S = verse.template.Structs;
const abx = verse.Antibiotic;
const Frame = verse.Frame;
const PageData = verse.template.PageData;
const Router = verse.Router;
const Git = @import("../../git.zig");
const log = std.log.scoped(.srctree_branches);
