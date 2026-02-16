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
    const vis: repos.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo = (repos.open(rd.name, vis, f.io) catch return error.Unknown) orelse return error.Unrouteable;
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
        .repo_header = .{
            .repo_name = rd.name,
            .description = try allocPrint(f.alloc, "{f}", .{
                abx.Html{ .text = repo.description(f.alloc, f.io) catch "" },
            }),
            .blame = null,
            .git_uri = null,
            .upstream = null,
        },
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
                        .code = b.data.?,
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
    var excludes: Exclude = .new;
    try excludes.fromRepo(repo, &tree, a, io);
    try excludes.fromSearch(str, a);
    defer excludes.list.deinit(a);
    for (excludes.list.items) |ex| log.warn("tree exclude {s}", .{ex});
    // TODO real tokenization
    const string = str[0 .. findScalarPos(u8, str, 0, ' ') orelse str.len];
    try searchTree(&files, &tree, repo, "", string, &excludes, &limit, a, io);

    var hits: ArrayList(S.SearchHtml.Files) = try .initCapacity(a, files.items.len);
    for (files.items) |hit| {
        var start: usize = hit.idx;
        var before: usize = 4;
        while (start > 0 and before > 0) : (start -|= 1) {
            if (hit.code[start] == '\n') before -|= 1;
        }
        var end: usize = hit.idx;
        var after: usize = 4;
        while (end < hit.code.len and after > 0) : (end += 1) {
            if (hit.code[end] == '\n') after -|= 1;
        }
        if (start > 0) start += 2;
        const code = hit.code[start .. end - 1];
        var line_number = hit.line + 1 - countScalar(u8, code[0 .. hit.idx - start], '\n');
        var writer: Writer.Allocating = try .initCapacity(a, code.len * 2);
        var source = std.mem.splitScalar(u8, code, '\n');
        while (source.next()) |line| {
            try writer.writer.print("<ln num=\"{}\" id=\"L{}\" href=\"#L{}\">{f}</ln>\n", .{
                line_number, line_number, line_number, abx.Html{ .text = line },
            });
            line_number += 1;
        }
        hits.appendAssumeCapacity(.{ .filename = hit.path, .line = hit.line + 1, .code = writer.written() });
    }

    return try hits.toOwnedSlice(a);
}

const Exclude = struct {
    list: ArrayList([]const u8),

    pub const new: Exclude = .{ .list = .{} };

    fn excluded(e: *Exclude, path: []const u8) bool {
        for (e.list.items, 0..) |ex, i| {
            if (startsWith(u8, path, ex)) {
                _ = e.list.swapRemove(i);
                return true;
            }
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
        for (tree.blobs) |obj| {
            if (eql(u8, obj.name, ".gitattributes")) {
                switch (repo.objects.load(obj.sha, a, io) catch return error.ServerFault) {
                    .tree, .commit, .tag => break,
                    .blob => |b| {
                        var r: Reader = .fixed(b.data.?);
                        while (r.takeSentinel('\n')) |line| {
                            if (endsWith(u8, line, "linguist-vendored") or endsWith(u8, line, " binary")) {
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

const Hit = struct {
    const Commit = struct {
        sha: git.Sha,
        idx: usize,

        pub fn init(s: git.Sha, idx: usize) Commit {
            return .{ .sha = s, .idx = idx };
        }
    };
    const File = struct {
        path: []const u8,
        sha: git.Sha,
        idx: usize,
        line: u32,
        code: []const u8,
    };
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const allocPrint = std.fmt.allocPrint;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const find = std.mem.find;
const eql = std.mem.eql;
const findPos = std.mem.findPos;
const findScalarPos = std.mem.findScalarPos;
const countScalar = std.mem.countScalar;
const log = std.log.scoped(.repo_search);

const repos = @import("../../repos.zig");
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
