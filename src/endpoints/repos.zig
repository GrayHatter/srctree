const std = @import("std");

const Allocator = std.mem.Allocator;

const Endpoint = @import("../endpoint.zig");
const Response = Endpoint.Response;
const HTML = Endpoint.HTML;
const DOM = Endpoint.DOM;
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;

const git = @import("../git.zig");

const endpoints = [_]Endpoint.Router.MatchRouter{
    .{ .name = "blob", .match = .{ .call = treeBlob } },
    .{ .name = "commits", .match = .{ .call = commits } },
    .{ .name = "tree", .match = .{ .call = treeBlob } },
};

pub fn router(uri: *UriIter) Error!Endpoint.Endpoint {
    const repo_name = uri.next() orelse return list;
    for (repo_name) |c| if (!std.ascii.isLower(c) and c != '.') return error.Unrouteable;

    if (uri.peek()) |_| {
        return Endpoint.Router.router(uri, &endpoints);
    } else {}

    var cwd = std.fs.cwd();
    if (cwd.openIterableDir("./repos", .{})) |idir| {
        var itr = idir.iterate();

        while (itr.next() catch return error.Unrouteable) |file| {
            if (file.kind != .directory and file.kind != .sym_link) continue;
            if (std.mem.eql(u8, file.name, repo_name)) return treeBlob;
        }
    } else |_| {}
    return error.Unrouteable;
}

fn commit(r: *Response, uri: []const u8) Error!void {
    return commits(r, uri);
}

fn htmlCommit(a: Allocator, c: git.Commit) !HTML.E {
    var foot = try a.alloc(HTML.E, 2);
    const prnt = c.parent[0] orelse "00000000";
    foot[0] = HTML.element("author", try a.dupe(u8, c.author.name), null);
    foot[1] = HTML.span(try std.fmt.allocPrint(a, "parent {s}", .{prnt[0..8]}));

    var data = try a.alloc(HTML.E, 2);
    data[0] = HTML.element(
        "data",
        try std.fmt.allocPrint(a, "{s}<br>{s}", .{ c.sha[0..8], c.message }),
        null,
    );
    data[1] = HTML.element("foot", foot, null);

    return HTML.commit(data, null);
}

fn commits(r: *Response, uri: *UriIter) Error!void {
    var cwd = std.fs.cwd();
    uri.reset();
    _ = uri.next();
    var name = uri.next() orelse return error.Unrouteable;

    var filename = try std.fmt.allocPrint(r.alloc, "./repos/{s}", .{name});
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadPacks(r.alloc) catch return error.Unknown;

    var lcommits = try r.alloc.alloc(HTML.E, 20);
    var current: git.Commit = repo.commit(r.alloc) catch return error.Unknown;
    for (lcommits, 0..) |*c, i| {
        c.* = try htmlCommit(r.alloc, current);
        current = current.toParent(r.alloc, 0) catch {
            lcommits.len = i;
            break;
        };
    }

    const htmlstr = try std.fmt.allocPrint(r.alloc, "{}", .{
        HTML.div(lcommits),
    });

    var tmpl = Template.find("commits.html");
    tmpl.init(r.alloc);
    tmpl.addVar("commits", htmlstr) catch return error.Unknown;

    var page = tmpl.buildFor(r.alloc, r) catch unreachable;

    r.status = .ok;
    r.start() catch return Error.Unknown;
    r.write(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}

fn sorter(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
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
            dom = dom.open(HTML.element("name", name, null));
            dom.push(HTML.anch(name, &[_]HTML.Attribute{
                .{ .key = "href", .value = try std.fmt.allocPrint(r.alloc, "/repo/{s}", .{name}) },
            }));
            dom = dom.close();
            dom.push(HTML.element("desc", null, null));
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
    uri.reset();
    _ = uri.next() orelse return error.InvalidURI; // repo
    const repo_name = uri.next() orelse return error.InvalidURI;

    var cwd = std.fs.cwd();
    var filename = try std.fmt.allocPrint(r.alloc, "./repos/{s}", .{repo_name});
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadPacks(r.alloc) catch return error.Unknown;

    const cmt = repo.commit(r.alloc) catch return error.Unknown;
    var files: git.Tree = cmt.mkTree(r.alloc) catch return error.Unknown;
    if (uri.next()) |blb| {
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
    dom = dom.open(HTML.element("lines", null, null));
    for (0..count + 1) |i| {
        var buf: [10]u8 = undefined;
        const b = std.fmt.bufPrint(&buf, "{}", .{i + 1}) catch unreachable;
        dom.push(HTML.element("ln", null, try HTML.Attribute.alloc(r.alloc, "num", b)));
    }
    dom = dom.close();
    dom = dom.open(HTML.element("code", null, null));
    var litr = std.mem.split(u8, d2, "\n");

    dom.push(HTML.span(litr.next().?));
    while (litr.next()) |line| {
        dom.push(HTML.text("\n"));
        dom.push(HTML.span(line));
    }
    dom = dom.close();
    var data = dom.done();
    const filestr = try std.fmt.allocPrint(r.alloc, "{}", .{HTML.divAttr(data, &[_]HTML.Attribute{HTML.Attribute.class("code-block")})});
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

    var lcommits = try r.alloc.alloc(HTML.E, 1);
    var repoo = repo;
    var current: git.Commit = repoo.commit(r.alloc) catch return error.Unknown;
    lcommits[0] = try htmlCommit(r.alloc, current);
    const commitstr = try std.fmt.allocPrint(r.alloc, "{}", .{
        HTML.div(lcommits),
    });
    tmpl.addVar("head-commit", commitstr) catch return Error.Unknown;

    var dom = DOM.new(r.alloc);
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
        dom = dom.open(HTML.anch(null, href));
        if (obj.isFile()) {
            dom.push(HTML.element("file", obj.name, null));
        } else {
            dom.push(HTML.element("tree", try dupeDir(r.alloc, obj.name), null));
        }
        //HTML.element("file", link, null);
        dom = dom.close();
    }
    var data = dom.done();
    const filestr = try std.fmt.allocPrint(r.alloc, "{}", .{HTML.div(data)});
    tmpl.addVar("files", filestr) catch return error.Unknown;
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;

    r.status = .ok;
    r.start() catch return Error.Unknown;
    r.write(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}
