const std = @import("std");

const Allocator = std.mem.Allocator;
const SplitIter = std.mem.SplitIterator(u8, .sequence);

const Endpoint = @import("../endpoint.zig");
const Response = Endpoint.Response;
const HTML = Endpoint.HTML;
const Template = Endpoint.Template;
const Error = Endpoint.Error;

const git = @import("../git.zig");

const Verbs = enum {
    tree,
    blob,
    commit,
    commits,

    pub fn from(str: []const u8) ?Verbs {
        inline for (@typeInfo(Verbs).Enum.fields) |v| {
            if (std.mem.eql(u8, v.name, str)) return @enumFromInt(v.value);
        }
        return null;
    }
};

pub fn router(uri: *SplitIter) Error!Endpoint.Endpoint {
    std.debug.print("ep route {}\n", .{uri});

    const itr_root = uri.first();
    std.debug.assert(itr_root.len >= 4);

    const repo_name = uri.next() orelse return list;

    for (repo_name) |c| if (!std.ascii.isLower(c) and c != '.') return error.Unrouteable;

    if (uri.next()) |verb| {
        if (Verbs.from(verb)) |vrb| switch (vrb) {
            .tree => {},
            .blob => {},
            .commit => return commit,
            .commits => return commits,
        };
    } else {}

    var cwd = std.fs.cwd();
    if (cwd.openIterableDir("./repos", .{})) |idir| {
        var itr = idir.iterate();

        while (itr.next() catch return error.Unrouteable) |file| {
            if (file.kind != .directory and file.kind != .sym_link) continue;
            if (std.mem.eql(u8, file.name, repo_name)) return tree;
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

fn commits(r: *Response, uri: []const u8) Error!void {
    var cwd = std.fs.cwd();
    var itr = std.mem.split(u8, uri, "/");
    _ = itr.next();
    _ = itr.next();
    var name = itr.next() orelse return error.Unrouteable;
    _ = itr.next();
    var filename = try std.fmt.allocPrint(r.alloc, "./repos/{s}", .{name});
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;

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

fn list(r: *Response, _: []const u8) Error!void {
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

        var repos = try r.alloc.alloc(HTML.E, flist.items.len);
        for (repos, flist.items) |*repoln, name| {
            var attr = try r.alloc.dupe(
                HTML.Attribute,
                &[_]HTML.Attribute{.{
                    .key = "href",
                    .value = try std.fmt.allocPrint(r.alloc, "/repo/{s}", .{name}),
                }},
            );
            var anc = try r.alloc.dupe(HTML.E, &[_]HTML.E{HTML.anch(name, attr)});
            repoln.* = HTML.li(anc, null);
        }

        var tmpl = Template.find("repos.html");
        tmpl.init(r.alloc);
        const repo = try std.fmt.allocPrint(r.alloc, "{}", .{HTML.element("repos", repos, null)});
        tmpl.addVar("repos", repo) catch return Error.Unknown;

        var page = tmpl.buildFor(r.alloc, r) catch unreachable;
        r.start() catch return Error.Unknown;
        r.write(page) catch return Error.Unknown;
        r.finish() catch return Error.Unknown;
    } else |err| {
        std.debug.print("unable to open given dir {}\n", .{err});
        return;
    }
}

fn tree(r: *Response, uri: []const u8) Error!void {
    var cwd = std.fs.cwd();
    var filename = try std.fmt.allocPrint(r.alloc, "./repos/{s}", .{uri[6..]});
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadPacks(r.alloc) catch return error.Unknown;

    var tmpl = Template.find("repo.html");
    tmpl.init(r.alloc);

    var head = repo.HEAD(r.alloc) catch return error.Unknown;
    tmpl.addVar("branch.default", head.branch.name) catch return error.Unknown;

    var refs = repo.refs(r.alloc) catch return error.Unknown;
    var a_refs = try r.alloc.alloc([]const u8, refs.len);
    for (a_refs, refs) |*dst, src| {
        dst.* = src.branch.name;
    }
    var str_refs = try std.mem.join(r.alloc, "\n", a_refs);
    tmpl.addVar("branches", str_refs) catch return error.Unknown;

    var files = repo.tree(r.alloc) catch return error.Unknown;
    var a_files = try r.alloc.alloc(HTML.E, files.objects.len);
    for (a_files, files.objects) |*dst, src| {
        dst.* = HTML.element("file", src.name, null);
    }

    const filestr = try std.fmt.allocPrint(r.alloc, "{}", .{HTML.div(a_files)});
    tmpl.addVar("files", filestr) catch return error.Unknown;

    var page = tmpl.buildFor(r.alloc, r) catch unreachable;

    r.status = .ok;
    r.start() catch return Error.Unknown;
    r.write(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}
