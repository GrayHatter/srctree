const std = @import("std");

const Allocator = std.mem.Allocator;

const Endpoint = @import("../endpoint.zig");
const Context = @import("../context.zig");
const Response = Endpoint.Response;
const Request = Endpoint.Request;
const HTML = Endpoint.HTML;
const elm = HTML.element;
const DOM = Endpoint.DOM;
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;

const git = @import("../git.zig");
const Ini = @import("../ini.zig");
const Humanize = @import("../humanize.zig");
const Bleach = @import("../bleach.zig");

const Commits = @import("repos/commits.zig");
const commits = Commits.commits;
const commit = Commits.commit;
const htmlCommit = Commits.htmlCommit;

const gitweb = @import("../gitweb.zig");

const endpoints = [_]Endpoint.Router.MatchRouter{
    .{ .name = "blob", .match = .{ .call = treeBlob } },
    .{ .name = "commits", .match = .{ .call = commits } },
    .{ .name = "commit", .match = .{ .call = commit } },
    .{ .name = "tree", .match = .{ .call = treeBlob } },
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
        if (cwd.openIterableDir("./repos", .{})) |idir| {
            var itr = idir.iterate();
            while (itr.next() catch return false) |file| {
                if (file.kind != .directory and file.kind != .sym_link) continue;
                if (std.mem.eql(u8, file.name, self.name)) return true;
            }
        } else |_| {}
        return false;
    }
};

pub fn router(ctx: *Context) Error!Endpoint.Endpoint {
    const rd = RouteData.make(&ctx.uri) orelse return list;

    if (rd.exists()) {
        if (rd.verb) |_| {
            _ = ctx.uri.next();
            _ = ctx.uri.next();
            return Endpoint.Router.router(ctx, &endpoints);
        } else return treeBlob;
    }
    return error.Unrouteable;
}

const dirs_first = true;
fn typeSorter(_: void, l: git.Blob, r: git.Blob) bool {
    if (l.isFile() == r.isFile()) return sorter({}, l.name, r.name);
    if (l.isFile() and !r.isFile()) return !dirs_first;
    return dirs_first;
}

fn repoSorter(_: void, l: []const u8, r: []const u8) bool {
    return sorter({}, l, r);
}

fn sorter(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

fn parseGitRemoteUrl(a: Allocator, url: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, url, "https://")) return try a.dupe(u8, url);

    if (std.mem.startsWith(u8, url, "git@")) {
        const end = if (std.mem.endsWith(u8, url, ".git")) url.len - 4 else url.len;
        var p = try a.dupe(u8, url[4..end]);
        if (std.mem.indexOf(u8, p, ":")) |i| p[i] = '/';
        const joiner = [_][]const u8{ "https://", p };
        var http = try std.mem.join(a, "", &joiner);
        return http;
    }

    return try a.dupe(u8, url);
}

fn htmlRepoBlock(a: Allocator, pre_dom: *DOM, name: []const u8, repo: git.Repo) !*DOM {
    var dom = pre_dom.open(HTML.repo());
    dom = dom.open(HTML.element("name", name, null));
    dom.dupe(HTML.anch(name, &[_]HTML.Attribute{
        .{ .key = "href", .value = try std.fmt.allocPrint(a, "/repo/{s}", .{name}) },
    }));
    dom = dom.close();
    dom = dom.open(HTML.element("desc", null, null));
    {
        const desc = try repo.description(a);
        if (!std.mem.startsWith(u8, desc, "Unnamed repository; edit this file")) {
            dom.push(HTML.p(desc, null));
        }

        var conffd = try repo.dir.openFile("config", .{});
        defer conffd.close();
        const conf = try Ini.init(a, conffd);
        if (conf.get("remote \"upstream\"")) |ns| {
            if (ns.get("url")) |url| {
                var purl = try parseGitRemoteUrl(a, url);
                dom = dom.open(HTML.p(null, &HTML.Attr.class("upstream")));
                dom.push(HTML.text("Upstream: "));
                dom.push(HTML.anch(purl, try HTML.Attr.create(a, "href", purl)));
                dom = dom.close();
            }
        }

        if (repo.commit(a)) |cmt| {
            defer cmt.raze(a);
            const committer = cmt.committer;
            const updated_str = try std.fmt.allocPrint(
                a,
                "updated about {}",
                .{Humanize.unix(committer.timestamp)},
            );
            dom.dupe(HTML.span(updated_str, &HTML.Attr.class("updated")));
        } else |_| {
            dom.dupe(HTML.span("new repo", &HTML.Attr.class("updated")));
        }
    }
    dom = dom.close();
    dom.push(HTML.element("last", null, null));
    return dom.close();
}

fn list(r: *Response, _: *UriIter) Error!void {
    var cwd = std.fs.cwd();
    if (cwd.openIterableDir("./repos", .{})) |idir| {
        var flist = std.ArrayList([]u8).init(r.alloc);
        var itr = idir.iterate();
        while (itr.next() catch return Error.Unknown) |file| {
            if (file.kind != .directory and file.kind != .sym_link) continue;
            if (file.name[0] == '.') continue;
            try flist.append(try r.alloc.dupe(u8, file.name));
        }
        std.sort.heap([]u8, flist.items, {}, repoSorter);

        var dom = DOM.new(r.alloc);

        if (r.request.auth.valid()) {
            dom = dom.open(HTML.element("div", null, &HTML.Attr.class("repo-btns")));
            dom.dupe(try HTML.btnLinkAlloc(r.alloc, "New Upstream", "/admin/clone-upstream"));
            dom = dom.close();
        }

        dom = dom.open(HTML.element("repos", null, null));

        for (flist.items) |name| {
            var repodir = idir.dir.openDir(name, .{}) catch return error.Unknown;
            errdefer repodir.close();
            var repo = git.Repo.init(repodir) catch return error.Unknown;
            repo.loadData(r.alloc) catch return error.Unknown;
            defer repo.raze(r.alloc);
            dom = htmlRepoBlock(r.alloc, dom, name, repo) catch return error.Unknown;
        }
        dom = dom.close();
        var data = dom.done();
        var tmpl = Template.find("repos.html");
        tmpl.init(r.alloc);
        _ = tmpl.addElements(r.alloc, "repos", data) catch return Error.Unknown;

        var page = tmpl.buildFor(r.alloc, r) catch unreachable;
        r.start() catch return Error.Unknown;
        r.send(page) catch return Error.Unknown;
        r.finish() catch return Error.Unknown;
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

fn newRepo(r: *Response, _: *UriIter) Error!void {
    var tmpl = Template.find("repo.html");
    tmpl.init(r.alloc);

    tmpl.addVar("files", "<h3>New Repo!</h3><p>Todo, add content here</p>") catch return error.Unknown;
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;

    r.status = .ok;
    r.start() catch return Error.Unknown;
    r.send(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}

fn treeBlob(r: *Response, uri: *UriIter) Error!void {
    const rd = RouteData.make(uri) orelse return error.Unrouteable;
    _ = uri.next();

    var cwd = std.fs.cwd();
    var filename = try std.fmt.allocPrint(r.alloc, "./repos/{s}", .{rd.name});
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(r.alloc) catch return error.Unknown;

    const cmt = repo.commit(r.alloc) catch return newRepo(r, uri);
    var files: git.Tree = cmt.mkTree(r.alloc) catch return error.Unknown;
    if (rd.verb) |blb| {
        if (std.mem.eql(u8, blb, "blob")) {
            return blob(r, uri, &repo, files);
        } else if (std.mem.eql(u8, blb, "tree")) {
            files = mkTree(r.alloc, repo, uri, files) catch return error.Unknown;
            return tree(r, uri, &repo, &files);
        } else return error.InvalidURI;
    } else files = cmt.mkTree(r.alloc) catch return error.Unknown;
    return tree(r, uri, &repo, &files);
}

fn blob(r: *Response, uri: *UriIter, repo: *git.Repo, pfiles: git.Tree) Error!void {
    var tmpl = Template.find("blob.html");
    tmpl.init(r.alloc);

    var blb: git.Blob = undefined;

    var files = pfiles;
    search: while (uri.next()) |bname| {
        for (files.objects) |obj| {
            if (std.mem.eql(u8, bname, obj.name)) {
                blb = obj;
                if (obj.isFile()) {
                    if (uri.next()) |_| return error.InvalidURI;
                    break :search;
                }
                files = git.Tree.fromRepo(r.alloc, repo.*, &obj.hash) catch return error.Unknown;
                continue :search;
            }
        } else return error.InvalidURI;
    }

    var dom = DOM.new(r.alloc);

    var resolve = repo.blob(r.alloc, &blb.hash) catch return error.Unknown;
    var reader = resolve.reader();

    var d2 = reader.readAllAlloc(r.alloc, 0xffffff) catch unreachable;
    const count = std.mem.count(u8, d2, "\n");
    dom = dom.open(HTML.element("code", null, null));
    var litr = std.mem.split(u8, d2, "\n");

    for (0..count + 1) |i| {
        var buf: [12]u8 = undefined;
        const b = std.fmt.bufPrint(&buf, "#L{}", .{i + 1}) catch unreachable;
        const attrs = try HTML.Attribute.alloc(r.alloc, &[_][]const u8{
            "num",
            "id",
            "href",
        }, &[_]?[]const u8{
            b[2..],
            b[1..],
            b,
        });
        const dirty = litr.next().?;
        var clean = try r.alloc.alloc(u8, dirty.len * 2);
        clean = Bleach.sanitize(dirty, clean, .{}) catch return error.Unknown;
        dom.push(HTML.element("ln", clean, attrs));
    }

    dom = dom.close();
    var data = dom.done();
    const filestr = try std.fmt.allocPrint(
        r.alloc,
        "{pretty}",
        .{HTML.divAttr(data, &HTML.Attr.class("code-block"))},
    );
    tmpl.addVar("files", filestr) catch return error.Unknown;
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;

    r.status = .ok;
    r.start() catch return Error.Unknown;
    r.send(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}

fn mkTree(a: Allocator, repo: git.Repo, uri: *UriIter, pfiles: git.Tree) !git.Tree {
    var files: git.Tree = pfiles;
    if (uri.next()) |udir| for (files.objects) |obj| {
        if (std.mem.eql(u8, udir, obj.name)) {
            files = try git.Tree.fromRepo(a, repo, &obj.hash);
            return try mkTree(a, repo, uri, files);
        }
    };
    return files;
}

fn tree(r: *Response, uri: *UriIter, repo: *git.Repo, files: *git.Tree) Error!void {
    var tmpl = Template.find("repo.html");
    tmpl.init(r.alloc);

    var head = if (repo.head) |h| switch (h) {
        .sha => |s| s,
        .branch => |b| b.name,
        else => "unknown",
    } else "unknown";
    tmpl.addVar("branch.default", head) catch return error.Unknown;

    var a_refs = try r.alloc.alloc([]const u8, repo.refs.len);
    for (a_refs, repo.refs) |*dst, src| {
        dst.* = src.branch.name;
    }
    var str_refs = try std.mem.join(r.alloc, "\n", a_refs);
    tmpl.addVar("branches", str_refs) catch return error.Unknown;

    const rd = RouteData.make(uri) orelse return error.Unrouteable;
    uri.reset();
    _ = uri.next();
    _ = uri.next();
    _ = uri.next();
    const file_uri_name = uri.rest();

    //if (std.mem.eql(u8, repo_name, "srctree")) {
    //var acts = repo.getActions(r.alloc);
    //acts.update() catch unreachable;
    //}

    var dom = DOM.new(r.alloc);
    var current: git.Commit = repo.commit(r.alloc) catch return error.Unknown;
    dom.pushSlice(try htmlCommit(r.alloc, current, rd.name, true));

    var commitblob = dom.done();
    const commitstr = try std.fmt.allocPrint(r.alloc, "{}", .{HTML.divAttr(
        commitblob,
        &HTML.Attr.class("treecommit"),
    )});
    tmpl.addVar("commit", commitstr) catch return error.Unknown;

    dom = DOM.new(r.alloc);

    if (file_uri_name.len > 0) {
        const end = std.mem.lastIndexOf(u8, file_uri_name[0 .. file_uri_name.len - 1], "/") orelse 0;
        dom = dom.open(HTML.element("tree", null, null));
        const dd_href = &[_]HTML.Attribute{.{
            .key = "href",
            .value = try std.fmt.allocPrint(
                r.alloc,
                "/repo/{s}/tree/{s}",
                .{ rd.name, file_uri_name[0..end] },
            ),
        }};
        dom.dupe(HTML.anch("..", dd_href));
        dom = dom.close();
    }
    try files.pushPath(r.alloc, file_uri_name);
    const changed = files.changedSet(r.alloc, repo) catch return error.Unknown;
    std.sort.pdq(git.Blob, files.objects, {}, typeSorter);
    for (files.objects) |obj| {
        var href = &[_]HTML.Attribute{.{
            .key = "href",
            .value = try std.fmt.allocPrint(r.alloc, "/repo/{s}/{s}/{s}{s}{s}", .{
                rd.name,
                if (obj.isFile()) "blob" else "tree",
                file_uri_name,
                obj.name,
                if (obj.isFile()) "" else "/",
            }),
        }};
        if (obj.isFile()) {
            dom = dom.open(HTML.element("file", null, null));
            dom.dupe(HTML.anch(obj.name, href));
        } else {
            dom = dom.open(HTML.element("tree", null, null));
            dom.dupe(HTML.anch(try dupeDir(r.alloc, obj.name), href));
        }
        //HTML.element("file", link, null);
        // I know... I KNOW!!!
        for (changed) |ch| {
            if (std.mem.eql(u8, ch.name, obj.name)) {
                dom.dupe(HTML.span(if (std.mem.indexOf(u8, ch.commit, "\n\n")) |i|
                    ch.commit[0..i]
                else
                    ch.commit, null));
                dom.dupe(HTML.span(try std.fmt.allocPrint(r.alloc, "{}", .{Humanize.unix(ch.timestamp)}), null));
                break;
            }
        }
        dom = dom.close();
    }
    var data = dom.done();
    _ = tmpl.addElements(r.alloc, "files", data) catch return error.Unknown;
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;

    r.status = .ok;
    r.start() catch return Error.Unknown;
    r.send(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}
