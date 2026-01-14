pub const verse_name = .search;

pub const verse_routes = [_]Router.Match{
    GET("search", repoSearchQuick),
    GET("quick", repoSearchQuick),
    GET("deep", repoSearchDeep),
};

pub const index = repoSearchQuick;

const SearchHtml = T.PageData("repo/search.html");

const SearchReq = struct {
    q: ?[]const u8,
};

fn repoSearch(f: *Frame, count: u32) Router.Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    var repo = (Repos.open(rd.name, .public, f.io) catch return error.Unknown) orelse return error.Unrouteable;
    repo.loadData(f.alloc, f.io) catch return error.ServerFault;

    const udata = f.request.data.query.validate(SearchReq) catch return error.DataInvalid;
    const str: ?[]const u8, const safe_str = if (udata.q) |usr_str|
        .{ usr_str, try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = usr_str }}) }
    else
        .{ null, "" };
    const commits, const files = if (str) |s|
        .{
            searchCommits(s, &repo, count >> 2, f.alloc, f.io) catch return error.ServerFault,
            searchFiles(s, &repo, count, f.alloc, f.io) catch |err| {
                log.err("search file err {}", .{err});
                return error.ServerFault;
            },
        }
    else
        .{ &.{}, &.{} };

    var page: SearchHtml = .init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .nav = .{ .nav_buttons = &try RepoEndpoint.navButtons(f) } },
        .repo_header = .{ .blame = null, .git_uri = null, .repo_name = rd.name, .upstream = null },
        .search = safe_str,
        .commits = commits,
        .count_files = files.len,
        .files = files,
    });

    return f.sendPage(&page);
}

fn repoSearchQuick(f: *Frame) Router.Error!void {
    try repoSearch(f, 1000);
}

fn repoSearchDeep(f: *Frame) Router.Error!void {
    try repoSearch(f, 200000);
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
        commit = commit.toParent(0, repo, a, io) catch break;
    }

    var hits: ArrayList(S.SearchHtml.Commits) = try .initCapacity(a, commits.items.len);
    for (hits.items) |hit| {
        _ = hit;
        //something
    }

    return try hits.toOwnedSlice(a);
}

fn searchTree(
    files: *ArrayList(Hit.File),
    tree: *git.Tree,
    repo: *git.Repo,
    root: []const u8,
    search_str: []const u8,
    ex: *Exclude,
    limit: *u32,
    a: Allocator,
    io: Io,
) !void {
    for (tree.blobs) |obj| {
        if (limit.* == 0) break;
        const path = if (root.len > 0)
            try allocPrint(a, "{s}/{s}", .{ root, obj.name })
        else
            obj.name;
        log.debug("searching {s}\n", .{path});
        if (ex.excluded(path)) {
            if (root.len > 0) a.free(path);
            continue;
        }
        limit.* -|= 1;
        var object = try repo.objects.load(obj.sha, a, io);
        switch (object) {
            .tree => |*t| searchTree(files, t, repo, path, search_str, ex, limit, a, io) catch |err| {
                log.err("search error {}", .{err});
                limit.* /= 2;
                continue;
            },
            .blob => |b| {
                std.debug.assert(b.isFile());
                if (find(u8, b.data.?, search_str)) |idx|
                    try files.append(a, .{
                        .path = path,
                        .sha = b.sha,
                        .idx = idx,
                        .line = @truncate(countScalar(u8, b.data.?[0..idx], '\n')),
                    });
            },
            .commit, .tag => return error.CorruptedRepo,
        }
    }
}

fn searchFiles(str: []const u8, repo: *git.Repo, limited: u32, a: Allocator, io: Io) ![]S.SearchHtml.Files {
    var limit: u32 = limited;
    var files: ArrayList(Hit.File) = .{};
    defer files.deinit(a);
    var commit = try repo.headCommit(a, io);
    var tree: git.Tree = try commit.loadTree(repo, a, io);
    var excludes: Exclude = try .fromRepo(repo, &tree, a, io);
    defer excludes.list.deinit(a);
    for (excludes.list.items) |ex| log.warn("tree exclude {s}", .{ex});
    try searchTree(&files, &tree, repo, "", str, &excludes, &limit, a, io);

    var hits: ArrayList(S.SearchHtml.Files) = try .initCapacity(a, files.items.len);
    for (files.items) |hit| {
        hits.appendAssumeCapacity(.{
            .filename = hit.path,
            .line = hit.line + 1,
        });
    }

    return try hits.toOwnedSlice(a);
}

const Exclude = struct {
    list: ArrayList([]const u8) = .{},

    fn excluded(e: *Exclude, path: []const u8) bool {
        for (e.list.items, 0..) |ex, i| {
            if (startsWith(u8, path, ex)) {
                _ = e.list.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    fn fromRepo(repo: *git.Repo, tree: *git.Tree, a: Allocator, io: Io) !Exclude {
        var list: ArrayList([]const u8) = .{};

        for (tree.blobs) |obj| {
            if (eql(u8, obj.name, ".gitattributes")) {
                switch (repo.objects.load(obj.sha, a, io) catch return error.ServerFault) {
                    .tree, .commit, .tag => break,
                    .blob => |b| {
                        var r: Reader = .fixed(b.data.?);
                        while (r.takeSentinel('\n')) |line| {
                            if (endsWith(u8, line, "linguist-vendored") or endsWith(u8, line, " binary")) {
                                if (find(u8, line, "/** ")) |idx| {
                                    try list.append(a, line[0..idx]);
                                }
                            }
                        } else |_| break;
                    },
                }
            }
        }

        return .{ .list = list };
    }
};

const Hit = struct {
    const Commit = struct {
        sha: git.SHA,
        idx: usize,

        pub fn init(s: git.SHA, idx: usize) Commit {
            return .{ .sha = s, .idx = idx };
        }
    };
    const File = struct {
        path: []const u8,
        sha: git.SHA,
        idx: usize,
        line: u32,
    };
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Reader = Io.Reader;
const allocPrint = std.fmt.allocPrint;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const find = std.mem.find;
const eql = std.mem.eql;
const findPos = std.mem.findPos;
const countScalar = std.mem.countScalar;
const log = std.log.scoped(.repo_search);

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
