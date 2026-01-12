pub const verse_name = .search;

pub const verse_routes = [_]Router.Match{
    GET("search", repoSearch),
    GET("searchDeep", repoSearchDeep),
};

pub const index = repoSearch;

const SearchHtml = T.PageData("repo/search.html");

const SearchReq = struct {
    q: ?[]const u8,
};

fn repoSearch(f: *Frame) Router.Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;

    var repo = (Repos.open(rd.name, .public, f.io) catch return error.Unknown) orelse return error.Unrouteable;

    const udata = f.request.data.query.validate(SearchReq) catch return error.DataInvalid;
    const str: ?[]const u8, const safe_str = if (udata.q) |usr_str|
        .{ usr_str, try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = usr_str }}) }
    else
        .{ null, "" };

    const commits, const files = if (str) |s|
        .{
            searchCommits(s, &repo, 300, f.alloc, f.io) catch return error.ServerFault,
            searchFiles(s, &repo, 300, f.alloc, f.io) catch return error.ServerFault,
        }
    else
        .{ &.{}, &.{} };

    var page: SearchHtml = .init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .nav = .{ .nav_buttons = &try RepoEndpoint.navButtons(f) } },
        .repo_header = .{ .blame = null, .git_uri = null, .repo_name = rd.name, .upstream = null },
        .search = safe_str,
        .commits = commits,
        .files = files,
    });

    return f.sendPage(&page);
}

fn repoSearchDeep(f: *Frame) Router.Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;

    var repo = (Repos.open(rd.name, .public, f.io) catch return error.Unknown) orelse return error.Unrouteable;

    const udata = f.request.data.query.validate(SearchReq) catch return error.DataInvalid;
    const str: ?[]const u8, const safe_str = if (udata.q) |usr_str|
        .{ usr_str, try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = usr_str }}) }
    else
        .{ null, "" };

    const commits, const files = if (str) |s|
        .{
            searchCommits(s, &repo, 20000, f.alloc, f.io) catch return error.ServerFault,
            searchFiles(s, &repo, 20000, f.alloc, f.io) catch return error.ServerFault,
        }
    else
        .{ &.{}, &.{} };

    var page: SearchHtml = .init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .nav = .{ .nav_buttons = &try RepoEndpoint.navButtons(f) } },
        .repo_header = .{ .blame = null, .git_uri = null, .repo_name = rd.name, .upstream = null },
        .search = safe_str,
        .commits = commits,
        .files = files,
    });

    return f.sendPage(&page);
}

fn searchCommits(str: []const u8, repo: *git.Repo, limited: u32, a: Allocator, io: Io) ![]S.SearchHtml.Commits {
    var limit: u32 = limited;
    var commits: ArrayList(Hit.Commit) = .{};
    defer commits.deinit(a);
    var commit = try repo.headCommit(a, io);

    while (limit > 0) : (limit -|= 1) {
        if (find(u8, commit.message, str)) |idx| {
            try commits.append(a, .init(commit.sha, idx));
        }
        if (commit.parent[0] == null) break;
        commit = try commit.toParent(0, repo, a, io);
    }

    var hits: ArrayList(S.SearchHtml.Commits) = try .initCapacity(a, commits.items.len);
    for (hits.items) |hit| {
        _ = hit;
        //something
    }

    return try a.dupe(S.SearchHtml.Commits, try hits.toOwnedSlice(a));
}

fn searchFiles(str: []const u8, repo: *git.Repo, limited: u32, a: Allocator, io: Io) ![]S.SearchHtml.Files {
    var limit: u32 = limited;
    var files: ArrayList(Hit.File) = .{};
    defer files.deinit(a);

    var commit = try repo.headCommit(a, io);
    var tree: git.Tree = try commit.loadTree(repo, a, io);
    while (limit > 0) : (limit -|= 1) {
        for (tree.blobs) |obj| {
            if (limit == 0) break;
            switch (try repo.objects.load(obj.sha, a, io)) {
                .tree => limit -|= 0,
                .blob => |b| {
                    const blob = try repo.loadBlob(b.sha, a, io);
                    std.debug.assert(blob.isFile());
                    if (find(u8, blob.data.?, str)) |idx| {
                        try files.append(a, .init(b.sha, idx));
                    }
                    limit -|= 0;
                },
                .commit, .tag => return error.CorruptedRepo,
            }
        }
    }

    var hits: ArrayList(S.SearchHtml.Files) = try .initCapacity(a, files.items.len);
    for (hits.items) |hit| {
        _ = hit;
        //something
    }

    return try a.dupe(S.SearchHtml.Files, try hits.toOwnedSlice(a));
}

fn searchTree() void {}

const Hit = struct {
    const Commit = struct {
        sha: git.SHA,
        idx: usize,

        pub fn init(s: git.SHA, idx: usize) Commit {
            return .{ .sha = s, .idx = idx };
        }
    };
    const File = struct {
        sha: git.SHA,
        idx: usize,

        pub fn init(s: git.SHA, idx: usize) File {
            return .{ .sha = s, .idx = idx };
        }
    };
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const allocPrint = std.fmt.allocPrint;
const find = std.mem.find;

const Repos = @import("../../repos.zig");
const RepoEndpoint = @import("../repos.zig");
const RouteData = RepoEndpoint.RouteData;
const git = @import("../../git.zig");

const verse = @import("verse");
const T = verse.template;
const S = verse.template.Structs;
const abx = verse.abx;
const Frame = verse.Frame;
const Router = verse.Router;
const Match = Router.Match;
const GET = Router.GET;
