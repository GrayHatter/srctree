const std = @import("std");

const Allocator = std.mem.Allocator;

const Endpoint = @import("../endpoint.zig");
const Response = Endpoint.Response;
const HTML = Endpoint.HTML;
const elm = HTML.element;
const DOM = Endpoint.DOM;
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;

const git = @import("../git.zig");
const Ini = @import("../ini.zig");

const Commits = @import("repos/commits.zig");
const commits = Commits.commits;
const commit = Commits.commit;
const htmlCommit = Commits.htmlCommit;

const endpoints = [_]Endpoint.Router.MatchRouter{
    .{ .name = "blob", .match = .{ .call = treeBlob } },
    .{ .name = "commits", .match = .{ .call = commits } },
    .{ .name = "commit", .match = .{ .call = commit } },
    .{ .name = "tree", .match = .{ .call = treeBlob } },
};

pub const RouteData = struct {
    name: []const u8,
    verb: ?[]const u8 = null,
    noun: ?[]const u8 = null,

    fn safe(name: ?[]const u8) ?[]const u8 {
        if (name) |n| {
            // why 30? who knows
            if (n.len > 30) return null;
            for (n) |c| if (!std.ascii.isLower(c) and c != '.') return null;
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
};

pub fn router(uri: *UriIter) Error!Endpoint.Endpoint {
    const rd = RouteData.make(uri) orelse return list;
    for (rd.name) |c| if (!std.ascii.isLower(c) and c != '.') return error.Unrouteable;

    var cwd = std.fs.cwd();
    if (cwd.openIterableDir("./repos", .{})) |idir| {
        var itr = idir.iterate();

        while (itr.next() catch return error.Unrouteable) |file| {
            if (file.kind != .directory and file.kind != .sym_link) continue;
            if (std.mem.eql(u8, file.name, rd.name)) {
                if (rd.verb) |_| {
                    _ = uri.next();
                    return Endpoint.Router.router(uri, &endpoints);
                } else return treeBlob;
            }
        }
    } else |_| {}
    return error.Unrouteable;
}

const dirs_first = true;
fn typeSorter(_: void, l: git.Blob, r: git.Blob) bool {
    if (l.isFile() == r.isFile()) return sorter({}, l.name, r.name);
    if (l.isFile() and !r.isFile()) return !dirs_first;
    return dirs_first;
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
        std.sort.heap([]u8, flist.items, {}, sorter);

        var dom = DOM.new(r.alloc);
        dom = dom.open(HTML.element("repos", null, null));

        for (flist.items) |name| {
            dom = dom.open(HTML.element("repo", null, null));
            {
                dom = dom.open(HTML.element("name", name, null));
                dom.dupe(HTML.anch(name, &[_]HTML.Attribute{
                    .{ .key = "href", .value = try std.fmt.allocPrint(r.alloc, "/repo/{s}", .{name}) },
                }));
            }
            dom = dom.close();
            dom = dom.open(HTML.element("desc", null, null));
            {
                var repodir = idir.dir.openDir(name, .{}) catch return error.Unknown;
                var repo = git.Repo.init(repodir) catch return error.Unknown;
                const desc = repo.description(r.alloc) catch return error.Unknown;
                if (!std.mem.startsWith(u8, desc, "Unnamed repository; edit this file")) {
                    dom.push(HTML.p(desc));
                }

                var conffd = repo.dir.openFile("config", .{}) catch return error.Unknown;
                const conf = Ini.init(r.alloc, conffd) catch return error.Unknown;
                if (conf.get("remote \"upstream\"")) |ns| {
                    if (ns.get("url")) |url| {
                        var purl = try parseGitRemoteUrl(r.alloc, url);
                        dom.push(HTML.anch(purl, try HTML.Attribute.create(r.alloc, "href", purl)));
                    }
                }
            }
            dom = dom.close();
            dom.push(HTML.element("last", null, null));
            dom = dom.close();
        }
        dom = dom.close();
        var data = dom.done();
        var tmpl = Template.find("repos.html");
        tmpl.init(r.alloc);
        _ = tmpl.addElements(r.alloc, "repos", data) catch return Error.Unknown;

        var page = tmpl.buildFor(r.alloc, r) catch unreachable;
        r.start() catch return Error.Unknown;
        r.write(page) catch return Error.Unknown;
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

fn treeBlob(r: *Response, uri: *UriIter) Error!void {
    const rd = RouteData.make(uri) orelse return error.Unrouteable;

    var cwd = std.fs.cwd();
    var filename = try std.fmt.allocPrint(r.alloc, "./repos/{s}", .{rd.name});
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadPacks(r.alloc) catch return error.Unknown;

    const cmt = repo.commit(r.alloc) catch return error.Unknown;
    var files: git.Tree = cmt.mkTree(r.alloc) catch return error.Unknown;
    if (rd.verb) |blb| {
        if (std.mem.eql(u8, blb, "blob")) {
            return blob(r, uri, repo, files);
        } else if (std.mem.eql(u8, blb, "tree")) {
            files = mkTree(r.alloc, repo, uri, files) catch return error.Unknown;
            return tree(r, uri, repo, files);
        } else return error.InvalidURI;
    } else files = cmt.mkTree(r.alloc) catch return error.Unknown;
    return tree(r, uri, repo, files);
}

fn blob(r: *Response, uri: *UriIter, repo: git.Repo, pfiles: git.Tree) Error!void {
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
                files = git.Tree.fromRepo(r.alloc, repo, &obj.hash) catch return error.Unknown;
                continue :search;
            }
        } else return error.InvalidURI;
    }

    var dom = DOM.new(r.alloc);

    var resolve = repo.blob(r.alloc, &blb.hash) catch return error.Unknown;
    var reader = resolve.reader();

    var d2 = reader.readAllAlloc(r.alloc, 0xffff) catch unreachable;
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
        dom.push(HTML.element("ln", litr.next().?, attrs));
    }

    dom = dom.close();
    var data = dom.done();
    const filestr = try std.fmt.allocPrint(
        r.alloc,
        "{pretty}",
        .{HTML.divAttr(data, &[_]HTML.Attribute{HTML.Attribute.class("code-block")})},
    );
    tmpl.addVar("files", filestr) catch return error.Unknown;
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;

    r.status = .ok;
    r.start() catch return Error.Unknown;
    r.write(page) catch return Error.Unknown;
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

fn tree(r: *Response, uri: *UriIter, repo: git.Repo, files: git.Tree) Error!void {
    var tmpl = Template.find("repo.html");
    tmpl.init(r.alloc);

    var head = repo._head orelse "unknown";
    tmpl.addVar("branch.default", head) catch return error.Unknown;

    var a_refs = try r.alloc.alloc([]const u8, repo.refs.len);
    for (a_refs, repo.refs) |*dst, src| {
        dst.* = src.branch.name;
    }
    var str_refs = try std.mem.join(r.alloc, "\n", a_refs);
    tmpl.addVar("branches", str_refs) catch return error.Unknown;

    uri.reset();
    _ = uri.next();
    const repo_name = uri.next() orelse return error.InvalidURI;
    _ = uri.next();
    const file_uri_name = uri.rest();

    //if (std.mem.eql(u8, repo_name, "srctree")) {
    //var acts = repo.getActions(r.alloc);
    //acts.update() catch unreachable;
    //}

    var dom = DOM.new(r.alloc);
    var repoo = repo;
    var current: git.Commit = repoo.commit(r.alloc) catch return error.Unknown;
    dom.pushSlice(try htmlCommit(r.alloc, current, true));

    var commitblob = dom.done();
    const commitstr = try std.fmt.allocPrint(r.alloc, "{}", .{HTML.divAttr(
        commitblob,
        &[_]HTML.Attribute{HTML.Attribute.class("treecommit")},
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
                .{ repo_name, file_uri_name[0..end] },
            ),
        }};
        dom.dupe(HTML.anch("..", dd_href));
        dom = dom.close();
    }
    std.sort.pdq(git.Blob, files.objects, {}, typeSorter);
    for (files.objects) |obj| {
        var href = &[_]HTML.Attribute{.{
            .key = "href",
            .value = try std.fmt.allocPrint(r.alloc, "/repo/{s}/{s}/{s}{s}{s}", .{
                repo_name,
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
        dom = dom.close();
    }
    var data = dom.done();
    _ = tmpl.addElements(r.alloc, "files", data) catch return error.Unknown;
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;

    r.status = .ok;
    r.start() catch return Error.Unknown;
    r.write(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}
