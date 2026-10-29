pub const verse_name = .search;

pub const verse_routes = [_]Router.Match{
    GET("search", repoSearchQuick),
    GET("quick", repoSearchQuick),
    GET("deep", repoSearchDeep),
};

pub const index = repoSearchQuick;

const SearchHtml = T.PageData("search.html");

const SearchReq = struct {
    q: ?[]const u8,
};

fn repoSearch(f: *Frame, count: u32) Router.Error!void {
    const rd = RouteData.init(f) orelse return error.ServerFault;
    const vis: Repo.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo = (Repo.openGit(rd.name, vis, f.io) catch return error.Unknown) orelse return error.ServerFault;
    repo.loadData(f.alloc, f.io) catch return error.ServerFault;

    const udata = f.request.data.query.validate(SearchReq) catch return error.DataInvalid;
    _ = count;
    const commits, const files = //if (udata.q) |s|
        //        .{
        //            searchCommits(s, &repo, count >> 2, f.alloc, f.io) catch return error.ServerFault,
        //            search.searchFiles(s, &repo, count, f.alloc, f.io) catch |err| {
        //                log.err("search file err {}", .{err});
        //                return error.ServerFault;
        //            },
        //        }
        //    else
        .{ &.{}, &.{} };

    //const dcount = rd.deltaCount(f);
    var page: SearchHtml = .init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .inbox_count = searchEP.inboxCount(f.user, f.alloc, f.io) },
        .count_files = files.len,
        .search = .abx(udata.q orelse &.{}),
        .search_results = &.{},
        .search_meta = .{
            .repos = &.{},
            .commits = commits,
            .files = files,
            .deltas = &.{},
        },
    });

    return f.sendPage(&page);
}

fn repoSearchQuick(f: *Frame) Router.Error!void {
    try repoSearch(f, 1000);
}

fn repoSearchDeep(f: *Frame) Router.Error!void {
    try repoSearch(f, 200000);
}

fn searchCommits(
    str: []const u8,
    repo: *git.Repo,
    limited: u32,
    a: Allocator,
    io: Io,
) ![]S.SearchHtml.Meta.Commits {
    var limit: u32 = limited;
    var commits: ArrayList(Search.Hit.Result.Commit) = .empty;
    defer commits.deinit(a);
    var commit = try repo.HEAD(a, io);

    while (limit > 0) : (limit -|= 1) {
        if (find(u8, commit.message, str)) |idx| {
            try commits.append(a, .init(commit.sha, idx));
        }
        if (commit.parent[0] == null) break;
        commit = commit.toParent(0, repo, a, io) catch break;
    }

    var hits: ArrayList(S.SearchHtml.Meta.Commits) = try .initCapacity(a, commits.items.len);
    for (hits.items) |hit| {
        _ = hit;
        //something
    }

    return try hits.toOwnedSlice(a);
}

fn searchTree(
    files: *ArrayList(Search.Hit.Result.File),
    tree: *git.Tree,
    repo: *git.Repo,
    root: []const u8,
    search_str: []const u8,
    ex: *Exclude,
    limit: *u32,
    a: Allocator,
    io: Io,
) !void {
    var itr = tree.iterate();
    while (itr.next()) |obj| {
        if (limit.* == 0) break;
        const path = if (root.len > 0)
            try a.print("{s}/{s}", .{ root, obj.name })
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
                if (find(u8, b.data.blob, search_str)) |idx|
                    try files.append(a, .{
                        .path = path,
                        .sha = b.sha,
                        .idx = idx,
                        .line = @truncate(countScalar(u8, b.data.blob[0..idx], '\n')),
                        .code = b.data.blob,
                    });
            },
            .commit, .tag => return error.CorruptedRepo,
        }
    }
}

const Exclude = struct {
    list: ArrayList([]const u8),

    pub const new: Exclude = .{ .list = .empty };

    fn excluded(e: *Exclude, path: []const u8) bool {
        for (e.list.items) |ex| {
            if (startsWith(u8, path, ex)) return true;
        }
        return false;
    }

    fn fromSearch(e: *Exclude, str: []const u8, a: Allocator) !void {
        var idx: usize = 0;
        while (idx < str.len) {
            if (findPos(u8, str, idx, "exclude:")) |pos| {
                idx = pos + 1;
                const end = findScalarPos(u8, str, pos, ' ') orelse str.len;
                try e.list.append(a, str[pos + 8 .. end]);
            } else return;
        }
    }

    fn fromRepo(e: *Exclude, repo: *git.Repo, tree: *git.Tree, a: Allocator, io: Io) !void {
        var itr = tree.iterate();
        while (itr.next()) |obj| {
            if (eql(u8, obj.name, ".gitattributes")) {
                switch (repo.objects.load(obj.sha, a, io) catch return error.ServerFault) {
                    .tree, .commit, .tag => break,
                    .blob => |b| {
                        var r: Reader = .fixed(b.data.blob);
                        while (r.takeSentinel('\n')) |line| {
                            if (endsWith(u8, line, "linguist-vendored") or endsWith(u8, line, " binary")) {
                                // Hacky guess instead of actually pattern
                                // matching, (sorry)
                                if (find(u8, line, "/** ")) |idx| {
                                    try e.list.append(a, line[0..idx]);
                                }
                            }
                        } else |_| break;
                    },
                }
            }
        }
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const find = std.mem.find;
const eql = std.mem.eql;
const findPos = std.mem.findPos;
const findScalarPos = std.mem.findScalarPos;
const countScalar = std.mem.countScalar;
const log = std.log.scoped(.repo_search);

const Repo = @import("../../Repo.zig");
const RepoEndpoint = @import("../repos.zig");
const searchEP = @import("../search.zig");
const RouteData = RepoEndpoint.RouteData;
const git = @import("../../git.zig");
const Search = @import("../../Search.zig");

const verse = @import("verse");
const T = verse.template;
const S = T.Structs;
const abx = verse.Antibiotic;
const Frame = verse.Frame;
const Router = verse.Router;
const Match = Router.Match;
const GET = Router.GET;
