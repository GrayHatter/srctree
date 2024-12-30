const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const bPrint = std.fmt.bufPrint;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;

const Verse = @import("verse");
const Request = Verse.Request;
const Template = Verse.Template;
const HTML = Verse.html;
const DOM = Verse.html.DOM;
const Route = Verse.Router;
const S = Template.Structs;
const elm = HTML.element;
const Error = Route.Error;
const UriIter = Route.UriIter;
const ROUTE = Route.ROUTE;
const POST = Route.POST;
const GET = Route.GET;
const RequestData = Verse.RequestData.RequestData;

const Bleach = @import("../bleach.zig");
const Humanize = @import("../humanize.zig");
const Ini = @import("../ini.zig");
const Repos = @import("../repos.zig");
const Git = @import("../git.zig");
const Highlight = @import("../syntax-highlight.zig");

const Commits = @import("repos/commits.zig");
const Diffs = @import("repos/diffs.zig");
const Issues = @import("repos/issues.zig");
const htmlCommit = Commits.htmlCommit;

const Types = @import("../types.zig");

const gitweb = @import("../gitweb.zig");

const endpoints = [_]Route.Match{
    ROUTE("", treeBlob),
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

    pub fn make(uri: *UriIter) ?RouteData {
        const index = uri.index;
        defer uri.index = index;
        uri.reset();
        _ = uri.next() orelse return null;
        return .{
            .name = safe(uri.next()) orelse return null,
            .verb = uri.next(),
            .noun = uri.next(),
        };
    }

    pub fn exists(self: RouteData) bool {
        var cwd = std.fs.cwd();
        var dir = cwd.openDir("./repos", .{ .iterate = true }) catch return false;
        defer dir.close();
        var itr = dir.iterate();
        while (itr.next() catch return false) |file| {
            if (file.kind != .directory and file.kind != .sym_link) continue;
            if (std.mem.eql(u8, file.name, self.name)) return true;
        }
        return false;
    }
};

pub fn navButtons(ctx: *Verse.Frame) ![2]Template.Structs.NavButtons {
    const rd = RouteData.make(&ctx.uri) orelse unreachable;
    if (!rd.exists()) unreachable;
    var i_count: usize = 0;
    var d_count: usize = 0;
    var itr = Types.Delta.iterator(ctx.alloc, rd.name);
    while (itr.next()) |dlt| {
        switch (dlt.attach) {
            .diff => d_count += 1,
            .issue => i_count += 1,
            else => {},
        }
        dlt.raze(ctx.alloc);
    }

    const btns = [2]Template.Structs.NavButtons{
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

pub fn router(ctx: *Verse.Frame) Route.RoutingError!Route.BuildFn {
    const rd = RouteData.make(&ctx.uri) orelse return list;

    if (rd.exists()) {
        var i_count: usize = 0;
        var d_count: usize = 0;
        var itr = Types.Delta.iterator(ctx.alloc, rd.name);
        while (itr.next()) |dlt| {
            switch (dlt.attach) {
                .diff => d_count += 1,
                .issue => i_count += 1,
                else => {},
            }
            dlt.raze(ctx.alloc);
        }

        if (rd.verb) |_| {
            _ = ctx.uri.next();
            _ = ctx.uri.next();
            return Route.router(ctx, &endpoints);
        } else return treeBlob;
    }
    return error.Unrouteable;
}

const dirs_first = true;
fn typeSorter(_: void, l: Git.Blob, r: Git.Blob) bool {
    if (l.isFile() == r.isFile()) return sorter({}, l.name, r.name);
    if (l.isFile() and !r.isFile()) return !dirs_first;
    return dirs_first;
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

fn repoBlock(a: Allocator, name: []const u8, repo: Git.Repo) !Template.Structs.RepoList {
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

    var tag: ?Template.Structs.Tag = null;

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

const ReposPage = Template.PageData("repos.html");

const RepoSortReq = struct {
    sort: ?[]const u8,
};

fn list(ctx: *Verse.Frame) Error!void {
    var cwd = std.fs.cwd();

    const udata = ctx.request.data.query.validate(RepoSortReq) catch return error.BadData;
    const tag_sort: bool = if (udata.sort) |srt| if (eql(u8, srt, "tag")) true else false else false;

    if (cwd.openDir("./repos", .{ .iterate = true })) |idir| {
        var repos = std.ArrayList(Git.Repo).init(ctx.alloc);
        var itr = idir.iterate();
        while (itr.next() catch return Error.Unknown) |file| {
            if (file.kind != .directory and file.kind != .sym_link) continue;
            if (file.name[0] == '.') continue;
            const rdir = idir.openDir(file.name, .{}) catch continue;
            var rpo = Git.Repo.init(rdir) catch continue;
            rpo.loadData(ctx.alloc) catch return error.Unknown;
            rpo.repo_name = ctx.alloc.dupe(u8, file.name) catch null;

            if (rpo.tags != null) {
                std.sort.heap(Git.Tag, rpo.tags.?, {}, tagSorter);
            }
            try repos.append(rpo);
        }

        std.sort.heap(Git.Repo, repos.items, repoctx{
            .alloc = ctx.alloc,
            .by = if (tag_sort) .tag else .commit,
        }, repoSorterNew);

        var repo_buttons: []const u8 = "";
        if (ctx.user.?.valid()) {
            repo_buttons =
                \\<div class="act-btns"><a class="btn" href="/admin/clone-upstream">New Upstream</a></div>
            ;
        }

        const repos_compiled = try ctx.alloc.alloc(Template.Structs.RepoList, repos.items.len);
        for (repos.items, repos_compiled) |*repo, *compiled| {
            defer repo.raze();
            compiled.* = repoBlock(ctx.alloc, repo.repo_name orelse "unknown", repo.*) catch {
                return error.Unknown;
            };
        }

        //var btns = [1]Template.Structs.NavButtons{.{
        //    .name = "inbox",
        //    .extra = 0,
        //    .url = "/inbox",
        //}};

        var page = ReposPage.init(.{
            .meta_head = .{ .open_graph = .{} },
            .body_header = (ctx.route_data.get(
                "body_header",
                *const S.BodyHeaderHtml,
            ) catch return error.Unknown).*,

            .buttons = .{ .buttons = repo_buttons },
            .repo_list = repos_compiled,
        });

        try ctx.sendPage(&page);
    } else |err| {
        std.debug.print("unable to open given dir {}\n", .{err});
        return;
    }
}

fn dupeDir(a: Allocator, name: []const u8) ![]u8 {
    var out = try a.alloc(u8, name.len + 1);
    @memcpy(out[0..name.len], name);
    out[name.len] = '/';
    return out;
}

const NewRepoPage = Template.PageData("repo-new.html");
fn newRepo(ctx: *Verse.Frame) Error!void {
    ctx.status = .ok;

    return error.NotImplemented;
}

fn treeBlob(ctx: *Verse.Frame) Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    _ = ctx.uri.next();

    var cwd = std.fs.cwd();
    const filename = try allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    const dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = Git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;
    defer repo.raze();

    const ograph: S.OpenGraph = .{
        .title = rd.name,
        .desc = desc: {
            var d = repo.description(ctx.alloc) catch return error.Unknown;
            if (startsWith(u8, d, "Unnamed repository; edit this file")) {
                d = try allocPrint(
                    ctx.alloc,
                    "An Indescribable repo with {s} commits",
                    .{"[todo count commits]"},
                );
            }
            break :desc d;
        },
    };

    _ = ograph;
    const cmt = repo.headCommit(ctx.alloc) catch return newRepo(ctx);
    if (rd.verb) |verb| {
        if (eql(u8, verb, "blob")) {
            const files: Git.Tree = cmt.mkTree(ctx.alloc, &repo) catch return error.Unknown;
            return blob(ctx, &repo, files);
        } else if (eql(u8, verb, "tree")) {
            var files: Git.Tree = cmt.mkTree(ctx.alloc, &repo) catch return error.Unknown;
            files = mkTree(ctx.alloc, &repo, &ctx.uri, files) catch return error.Unknown;
            return tree(ctx, &repo, &files);
        } else if (eql(u8, verb, "")) {
            var files: Git.Tree = cmt.mkTree(ctx.alloc, &repo) catch return error.Unknown;
            return tree(ctx, &repo, &files);
        } else return error.InvalidURI;
    } else {
        var files: Git.Tree = cmt.mkTree(ctx.alloc, &repo) catch return error.Unknown;
        return tree(ctx, &repo, &files);
    }
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

const BlamePage = Template.PageData("blame.html");

fn blame(ctx: *Verse.Frame) Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    std.debug.assert(std.mem.eql(u8, rd.verb orelse "", "blame"));
    _ = ctx.uri.next();
    const blame_file = ctx.uri.rest();

    var cwd = std.fs.cwd();
    const fname = try allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    const dir = cwd.openDir(fname, .{}) catch return error.Unknown;
    var repo = Git.Repo.init(dir) catch return error.Unknown;
    defer repo.raze();

    var actions = repo.getAgent(ctx.alloc);
    actions.cwd = cwd.openDir(fname, .{}) catch unreachable;
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
    } else Bleach.Html.sanitizeAlloc(ctx.alloc, source_lines.items) catch return error.Unknown;

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
        .body_header = (ctx.route_data.get(
            "body_header",
            *const S.BodyHeaderHtml,
        ) catch return error.Unknown).*,
        .filename = Bleach.Html.sanitizeAlloc(ctx.alloc, blame_file) catch unreachable,
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
                .author = Bleach.Html.sanitizeAlloc(a, bcommit.author.name) catch unreachable,
                .email = Bleach.Html.sanitizeAlloc(a, bcommit.author.email) catch unreachable,
            },
            .time = try Humanize.unix(bcommit.author.timestamp).printAlloc(a),
            .num = i + 1,
            .line = src.line,
        };
    }
    return b_lines;
}

fn wrapLineNumbers(a: Allocator, text: []const u8) ![]S.BlobLines {
    // TODO

    var litr = splitScalar(u8, text, '\n');
    const count = std.mem.count(u8, text, "\n");
    const lines = try a.alloc(S.BlobLines, count + 1);
    var i: usize = 0;
    while (litr.next()) |line| {
        lines[i] = .{
            .num = i + 1,
            .line = line,
        };
        i += 1;
    }
    return lines;
}

fn excludedExt(name: []const u8) bool {
    const exclude_ext = [_][:0]const u8{
        ".jpg",
        ".jpeg",
        ".gif",
        ".png",
    };
    inline for (exclude_ext) |un| {
        if (std.mem.endsWith(u8, name, un)) return true;
    }
    return false;
}

const BlobPage = Template.PageData("blob.html");

fn blob(vrs: *Verse.Frame, repo: *Git.Repo, pfiles: Git.Tree) Error!void {
    var blb: Git.Blob = undefined;

    var files = pfiles;
    search: while (vrs.uri.next()) |bname| {
        for (files.blobs) |obj| {
            if (std.mem.eql(u8, bname, obj.name)) {
                blb = obj;
                if (obj.isFile()) {
                    if (vrs.uri.next()) |_| return error.InvalidURI;
                    break :search;
                }
                const treeobj = repo.loadObject(vrs.alloc, obj.sha) catch return error.Unknown;
                files = Git.Tree.initOwned(obj.sha, vrs.alloc, treeobj) catch return error.Unknown;
                continue :search;
            }
        } else return error.InvalidURI;
    }

    var resolve = repo.loadBlob(vrs.alloc, blb.sha) catch return error.Unknown;
    if (!resolve.isFile()) return error.Unknown;
    var formatted: []const u8 = undefined;
    if (Highlight.Language.guessFromFilename(blb.name)) |lang| {
        const pre = try Highlight.highlight(vrs.alloc, lang, resolve.data.?);
        formatted = pre[28..][0 .. pre.len - 38];
    } else if (excludedExt(blb.name)) {
        formatted = "This file type is currently unsupported";
    } else {
        formatted = Bleach.Html.sanitizeAlloc(vrs.alloc, resolve.data.?) catch return error.Unknown;
    }

    const wrapped = try wrapLineNumbers(vrs.alloc, formatted);

    vrs.uri.reset();
    _ = vrs.uri.next();
    const uri_repo = vrs.uri.next() orelse return error.Unrouteable;
    _ = vrs.uri.next();
    const uri_filename = Bleach.Html.sanitizeAlloc(vrs.alloc, vrs.uri.rest()) catch return error.Unknown;

    vrs.status = .ok;

    var btns = navButtons(vrs) catch return error.Unknown;
    // TODO fixme
    _ = &btns;

    var page = BlobPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = (vrs.route_data.get(
            "body_header",
            *const S.BodyHeaderHtml,
        ) catch return error.Unknown).*,
        .repo = uri_repo,
        .uri_filename = uri_filename,
        .filename = blb.name,
        .blob_lines = wrapped,
    });

    try vrs.sendPage(&page);
}

fn mkTree(a: Allocator, repo: *const Git.Repo, uri: *UriIter, pfiles: Git.Tree) !Git.Tree {
    var files: Git.Tree = pfiles;
    if (uri.next()) |udir| for (files.blobs) |obj| {
        if (std.mem.eql(u8, udir, obj.name)) {
            const treeobj = try repo.loadObject(a, obj.sha);
            files = try Git.Tree.initOwned(obj.sha, a, treeobj);
            return try mkTree(a, repo, uri, files);
        }
    };
    return files;
}

fn htmlReadme(a: Allocator, readme: []const u8) ![]HTML.E {
    var dom = DOM.new(a);

    dom = dom.open(HTML.element("readme", null, null));
    dom.push(HTML.element("intro", "README.md", null));
    dom = dom.open(HTML.element("code", null, null));
    const clean = Bleach.Html.sanitizeAlloc(a, readme) catch return error.Unknown;
    const translated = try Highlight.translate(a, .markdown, clean);
    var litr = std.mem.splitScalar(u8, translated, '\n');
    while (litr.next()) |line| {
        dom.push(HTML.element("ln", line, null));
    }
    dom = dom.close();
    dom = dom.close();

    return dom.done();
}

fn isReadme(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, "README.md")) return true;
    return false;
}

fn drawFileLine(
    a: Allocator,
    ddom: *DOM,
    rname: []const u8,
    base: []const u8,
    obj: Git.Blob,
    ch: Git.ChangeSet,
) !*DOM {
    var dom = ddom;
    if (obj.isFile()) {
        dom = try drawBlob(a, dom, rname, base, obj);
    } else {
        dom = try drawTree(a, dom, rname, base, obj);
    }

    // I know... I KNOW!!!
    dom = dom.open(HTML.div(null, null));
    const commit_href = try allocPrint(a, "/repo/{s}/commit/{s}", .{ rname, ch.sha.hex[0..8] });
    dom.push(try HTML.aHrefAlloc(a, ch.commit_title, commit_href));
    dom.dupe(HTML.span(try allocPrint(a, "{}", .{Humanize.unix(ch.timestamp)}), null));
    dom = dom.close();
    return dom.close();
}

fn drawBlob(a: Allocator, ddom: *DOM, rname: []const u8, base: []const u8, obj: Git.Blob) !*DOM {
    var dom = ddom.open(HTML.element("file", null, null));
    const file_link = try allocPrint(a, "/repo/{s}/blob/{s}{s}", .{ rname, base, obj.name });

    const href = &[_]HTML.Attribute{.{
        .key = "href",
        .value = file_link,
    }};
    dom.dupe(HTML.anch(obj.name, href));

    return dom;
}

fn drawTree(a: Allocator, ddom: *DOM, rname: []const u8, base: []const u8, obj: Git.Blob) !*DOM {
    var dom = ddom.open(HTML.element("tree", null, null));
    const file_link = try allocPrint(a, "/repo/{s}/tree/{s}{s}/", .{ rname, base, obj.name });

    const href = &[_]HTML.Attribute{.{
        .key = "href",
        .value = file_link,
    }};
    dom.dupe(HTML.anch(try dupeDir(a, obj.name), href));
    return dom;
}

const TreePage = Template.PageData("tree.html");

fn tree(ctx: *Verse.Frame, repo: *Git.Repo, files: *Git.Tree) Error!void {
    //const head = if (repo.head) |h| switch (h) {
    //    .sha => |s| s.hex[0..],
    //    .branch => |b| b.name,
    //    else => "unknown",
    //} else "unknown";
    //ctx.putVerse("Branch.default", .{ .slice = head }) catch return error.Unknown;

    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    ctx.uri.reset();
    _ = ctx.uri.next();
    _ = ctx.uri.next();
    _ = ctx.uri.next();
    const uri_base = ctx.uri.rest();

    var dom = DOM.new(ctx.alloc);

    dom = dom.open(HTML.element("repo", null, &HTML.Attr.class("landing")));

    dom = dom.open(HTML.element("intro", null, null));
    dom.push(HTML.h3(rd.name, null));
    const branches = try allocPrint(ctx.alloc, "{} branches", .{repo.refs.len});
    dom.push(HTML.span(branches, null));

    const c = repo.headCommit(ctx.alloc) catch return error.Unknown;
    dom.push(HTML.span(c.title[0..@min(c.title.len, 50)], null));
    const commit_time = try allocPrint(ctx.alloc, "  {}", .{Humanize.unix(c.committer.timestamp)});
    dom = dom.open(HTML.span(null, &HTML.Attr.class("muted")));
    const commit_href = try allocPrint(ctx.alloc, "/repo/{s}/commit/{s}", .{ rd.name, c.sha.hex[0..8] });
    dom.push(HTML.text(commit_time));
    dom.push(try HTML.aHrefAlloc(ctx.alloc, c.sha.hex[0..8], commit_href));
    dom = dom.close();
    dom = dom.close();

    dom = dom.open(HTML.div(null, &HTML.Attr.class("treelist")));
    if (uri_base.len > 0) {
        const end = std.mem.lastIndexOf(u8, uri_base[0 .. uri_base.len - 1], "/") orelse 0;
        dom = dom.open(HTML.element("tree", null, null));
        const dd_href = &[_]HTML.Attribute{.{
            .key = "href",
            .value = try allocPrint(
                ctx.alloc,
                "/repo/{s}/tree/{s}",
                .{ rd.name, uri_base[0..end] },
            ),
        }};
        dom.dupe(HTML.anch("..", dd_href));
        dom = dom.close();
    }
    try files.pushPath(ctx.alloc, uri_base);
    if (files.changedSet(ctx.alloc, repo)) |changed| {
        std.sort.pdq(Git.Blob, files.blobs, {}, typeSorter);
        for (files.blobs) |obj| {
            for (changed) |ch| {
                if (std.mem.eql(u8, ch.name, obj.name)) {
                    dom = try drawFileLine(ctx.alloc, dom, rd.name, uri_base, obj, ch);
                    break;
                }
            }
        }
    } else |err| switch (err) {
        error.PathNotFound => {
            dom.push(HTML.h3("unable to find this file", null));
        },
        else => return error.Unrouteable,
    }
    dom = dom.close();

    dom = dom.close();
    const repo_data = dom.done();

    var readme: ?[]const u8 = null;

    for (files.blobs) |obj| {
        if (isReadme(obj.name)) {
            const resolve = repo.blob(ctx.alloc, obj.sha) catch return error.Unknown;
            const readme_html = htmlReadme(ctx.alloc, resolve.data.?) catch unreachable;
            readme = try std.fmt.allocPrint(ctx.alloc, "{pretty}", .{readme_html[0]});
            break;
        }
    }

    //var btns = navButtons(ctx) catch return error.Unknown;

    var page = TreePage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = (ctx.route_data.get(
            "body_header",
            *const S.BodyHeaderHtml,
        ) catch return error.Unknown).*,
        .upstream = null,
        .repo_name = rd.name,
        .repo = try allocPrint(ctx.alloc, "{s}", .{repo_data[0]}),
        .readme = readme,
    });

    try ctx.sendPage(&page);
}

const TagPage = Template.PageData("repo-tags.html");

fn tagsList(ctx: *Verse.Frame) Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;

    var cwd = std.fs.cwd();
    const filename = try allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    const dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = Git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;
    defer repo.raze();

    std.sort.heap(Git.Tag, repo.tags.?, {}, tagSorter);

    const tstack = try ctx.alloc.alloc(Template.Structs.Tags, repo.tags.?.len);

    for (repo.tags.?, tstack) |tag, *html| {
        html.name = tag.name;
    }

    //var btns = navButtons(ctx) catch return error.Unknown;
    var page = TagPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = (ctx.route_data.get(
            "body_header",
            *const S.BodyHeaderHtml,
        ) catch return error.Unknown).*,
        .upstream = null,
        .tags = tstack,
    });

    try ctx.sendPage(&page);
}
