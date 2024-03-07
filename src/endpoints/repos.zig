const std = @import("std");

const Allocator = std.mem.Allocator;
const aPrint = std.fmt.allocPrint;
const bPrint = std.fmt.bufPrint;

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

const Bleach = @import("../bleach.zig");
const Humanize = @import("../humanize.zig");
const Ini = @import("../ini.zig");
const Repos = @import("../repos.zig");
const git = @import("../git.zig");

const Commits = @import("repos/commits.zig");
const Diffs = @import("repos/diffs.zig");
const Issues = @import("repos/issues.zig");
const commit = Commits.commit;
const htmlCommit = Commits.htmlCommit;

const Types = @import("../types.zig");

const gitweb = @import("../gitweb.zig");

const endpoints = [_]Endpoint.Router.MatchRouter{
    .{ .name = "", .match = .{ .call = treeBlob } },
    .{ .name = "blob", .match = .{ .call = treeBlob } },
    .{ .name = "commits", .match = .{ .simple = &Commits.routes } },
    .{ .name = "commit", .match = .{ .call = commit } },
    .{ .name = "tree", .match = .{ .call = treeBlob } },
    .{ .name = "diffs", .match = .{ .route = &Diffs.router } },
    .{ .name = "issues", .match = .{ .route = &Issues.router } },
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
        if (cwd.openDir("./repos", .{ .iterate = true })) |idir| {
            var itr = idir.iterate();
            while (itr.next() catch return false) |file| {
                if (file.kind != .directory and file.kind != .sym_link) continue;
                if (std.mem.eql(u8, file.name, self.name)) return true;
            }
        } else |_| {}
        return false;
    }
};

pub fn router(ctx: *Context) Error!Endpoint.Router.Callable {
    const rd = RouteData.make(&ctx.uri) orelse return list;

    if (rd.exists()) {
        var i_count: usize = 0;
        var d_count: usize = 0;
        var itr = Types.Deltas.iterator(ctx.alloc, rd.name);
        while (itr.next()) |dlt| {
            switch (dlt.attach) {
                .diff => d_count += 1,
                .issue => i_count += 1,
                else => {},
            }
            dlt.raze(ctx.alloc);
        }

        try ctx.addRouteVar("repo_name", rd.name);
        const issueurl = try std.fmt.allocPrint(ctx.alloc, "/repos/{s}/issues/", .{rd.name});
        try ctx.addRouteVar("issueurl", issueurl);

        const issuecnt = try std.fmt.allocPrint(ctx.alloc, "{}", .{i_count});
        try ctx.addRouteVar("issuecount", issuecnt);
        const diffcnt = try std.fmt.allocPrint(ctx.alloc, "{}", .{d_count});
        try ctx.addRouteVar("diffcount", diffcnt);
        const diffurl = try std.fmt.allocPrint(ctx.alloc, "/repos/{s}/diffs/", .{rd.name});
        try ctx.addRouteVar("diffurl", diffurl);
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

const repoctx = struct {
    alloc: Allocator,
};

fn repoSorterNew(ctx: repoctx, l: git.Repo, r: git.Repo) bool {
    return !repoSorter(ctx, l, r);
}

fn repoSorter(ctx: repoctx, l: git.Repo, r: git.Repo) bool {
    var lc = l.commit(ctx.alloc) catch return true;
    defer lc.raze(ctx.alloc);
    var rc = r.commit(ctx.alloc) catch return false;
    defer rc.raze(ctx.alloc);
    return sorter({}, lc.committer.timestr, rc.committer.timestr);
}

fn sorter(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

fn htmlRepoBlock(a: Allocator, pre_dom: *DOM, name: []const u8, repo: git.Repo) !*DOM {
    var dom = pre_dom.open(HTML.repo());
    dom = dom.open(HTML.element("name", name, null));
    dom.dupe(HTML.anch(name, &[_]HTML.Attribute{
        .{ .key = "href", .value = try aPrint(a, "/repo/{s}", .{name}) },
    }));
    dom = dom.close();
    dom = dom.open(HTML.element("desc", null, null));
    {
        const desc = try repo.description(a);
        if (!std.mem.startsWith(u8, desc, "Unnamed repository; edit this file")) {
            dom.push(HTML.p(desc, null));
        }

        // upstream
        if (try Repos.hasUpstream(a, repo)) |url| {
            const purl = try Repos.parseGitRemoteUrl(a, url);
            dom = dom.open(HTML.p(null, &HTML.Attr.class("upstream")));
            dom.push(HTML.text("Upstream: "));
            dom.push(HTML.anch(purl, try HTML.Attr.create(a, "href", purl)));
            dom = dom.close();
        }

        if (repo.commit(a)) |cmt| {
            defer cmt.raze(a);
            const committer = cmt.committer;
            const updated_str = try aPrint(
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

fn list(ctx: *Context) Error!void {
    var cwd = std.fs.cwd();
    if (cwd.openDir("./repos", .{ .iterate = true })) |idir| {
        var repos = std.ArrayList(git.Repo).init(ctx.alloc);
        var itr = idir.iterate();
        while (itr.next() catch return Error.Unknown) |file| {
            if (file.kind != .directory and file.kind != .sym_link) continue;
            if (file.name[0] == '.') continue;
            const rdir = idir.openDir(file.name, .{}) catch continue;
            var rpo = git.Repo.init(rdir) catch continue;
            rpo.loadData(ctx.alloc) catch return error.Unknown;
            rpo.repo_name = ctx.alloc.dupe(u8, file.name) catch null;
            try repos.append(rpo);
        }
        std.sort.heap(git.Repo, repos.items, repoctx{ .alloc = ctx.alloc }, repoSorterNew);

        var dom = DOM.new(ctx.alloc);

        if (ctx.response.request.auth.valid()) {
            dom = dom.open(HTML.div(null, &HTML.Attr.class("act-btns")));
            dom.dupe(try HTML.linkBtnAlloc(ctx.alloc, "New Upstream", "/admin/clone-upstream"));
            dom = dom.close();
        }

        dom = dom.open(HTML.element("repos", null, null));

        for (repos.items) |*repo| {
            defer repo.raze(ctx.alloc);
            dom = htmlRepoBlock(
                ctx.alloc,
                dom,
                repo.repo_name orelse "unknown",
                repo.*,
            ) catch return error.Unknown;
        }
        dom = dom.close();
        const data = dom.done();
        var tmpl = Template.find("repos.html");
        tmpl.init(ctx.alloc);
        _ = tmpl.addElements(ctx.alloc, "repos", data) catch return Error.Unknown;

        try ctx.sendTemplate(&tmpl);
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

fn newRepo(ctx: *Context) Error!void {
    var tmpl = Template.find("repo.html");
    tmpl.init(ctx.alloc);

    tmpl.addVar("files", "<h3>New Repo!</h3><p>Todo, add content here</p>") catch return error.Unknown;
    ctx.response.status = .ok;

    try ctx.sendTemplate(&tmpl);
}

fn treeBlob(ctx: *Context) Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    _ = ctx.uri.next();

    var cwd = std.fs.cwd();
    const filename = try aPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    const dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;

    const cmt = repo.commit(ctx.alloc) catch return newRepo(ctx);
    var files: git.Tree = cmt.mkTree(ctx.alloc) catch return error.Unknown;
    if (rd.verb) |blb| {
        if (std.mem.eql(u8, blb, "blob")) {
            return blob(ctx, &repo, files);
        } else if (std.mem.eql(u8, blb, "tree")) {
            files = mkTree(ctx.alloc, repo, &ctx.uri, files) catch return error.Unknown;
            return tree(ctx, &repo, &files);
        } else if (std.mem.eql(u8, blb, "")) { // There's a better way to do this
            files = cmt.mkTree(ctx.alloc) catch return error.Unknown;
        } else return error.InvalidURI;
    } else files = cmt.mkTree(ctx.alloc) catch return error.Unknown;
    return tree(ctx, &repo, &files);
}

fn guessLang(name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, name, ".zig")) {
        return "zig";
    } else if (std.mem.endsWith(u8, name, ".html")) {
        return "html";
    } else if (std.mem.endsWith(u8, name, ".h")) {
        return "cpp";
    } else if (std.mem.endsWith(u8, name, ".c")) {
        return "c";
    } else if (std.mem.endsWith(u8, name, ".cpp")) {
        return "cpp";
    }
    return "text";
}

fn blob(ctx: *Context, repo: *git.Repo, pfiles: git.Tree) Error!void {
    var tmpl = Template.find("blob.html");
    tmpl.init(ctx.alloc);

    var blb: git.Blob = undefined;

    var files = pfiles;
    search: while (ctx.uri.next()) |bname| {
        for (files.objects) |obj| {
            if (std.mem.eql(u8, bname, obj.name)) {
                blb = obj;
                if (obj.isFile()) {
                    if (ctx.uri.next()) |_| return error.InvalidURI;
                    break :search;
                }
                files = git.Tree.fromRepo(ctx.alloc, repo.*, &obj.hash) catch return error.Unknown;
                continue :search;
            }
        } else return error.InvalidURI;
    }

    var dom = DOM.new(ctx.alloc);

    var resolve = repo.blob(ctx.alloc, &blb.hash) catch return error.Unknown;
    var reader = resolve.reader();

    const d2 = reader.readAllAlloc(ctx.alloc, 0xffffff) catch unreachable;
    var child = std.ChildProcess.init(&[_][]const u8{ "pygmentize", "-f", "html", "-l", guessLang(blb.name) }, ctx.alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.expand_arg0 = .no_expand;
    child.spawn() catch unreachable;

    const err_mask = std.os.POLL.ERR | std.os.POLL.NVAL | std.os.POLL.HUP;
    var poll_fd = [_]std.os.pollfd{
        .{
            .fd = child.stdout.?.handle,
            .events = std.os.POLL.IN,
            .revents = undefined,
        },
    };
    _ = std.os.write(child.stdin.?.handle, d2) catch unreachable;
    std.os.close(child.stdin.?.handle);
    child.stdin = null;

    var buf = std.ArrayList(u8).init(ctx.alloc);
    const abuf = try ctx.alloc.alloc(u8, 0xffffff);
    while (true) {
        const events_len = std.os.poll(&poll_fd, std.math.maxInt(i32)) catch unreachable;
        if (events_len == 0) continue;
        if (poll_fd[0].revents & std.os.POLL.IN != 0) {
            const amt = std.os.read(poll_fd[0].fd, abuf) catch unreachable;
            if (amt == 0) break;
            try buf.appendSlice(abuf[0..amt]);
        } else if (poll_fd[0].revents & err_mask != 0) {
            break;
        }
    }
    ctx.alloc.free(abuf);

    _ = child.wait() catch unreachable;
    const formatted = try buf.toOwnedSlice();

    dom = dom.open(HTML.element("code", null, null));
    var litr = std.mem.split(u8, formatted[28..][0 .. formatted.len - 38], "\n");

    const count = std.mem.count(u8, d2, "\n");
    for (0..count + 1) |i| {
        var pbuf: [12]u8 = undefined;
        const b = std.fmt.bufPrint(&pbuf, "#L{}", .{i + 1}) catch unreachable;
        const attrs = try HTML.Attribute.alloc(ctx.alloc, &[_][]const u8{
            "num",
            "id",
            "href",
        }, &[_]?[]const u8{
            b[2..],
            b[1..],
            b,
        });
        const line = litr.next().?;
        dom.push(HTML.element("ln", line, attrs));
    }

    dom = dom.close();
    const data = dom.done();
    const filestr = try aPrint(
        ctx.alloc,
        "{pretty}",
        .{HTML.div(data, &HTML.Attr.class("code-block"))},
    );
    tmpl.addVar("files", filestr) catch return error.Unknown;
    ctx.response.status = .ok;

    try ctx.sendTemplate(&tmpl);
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

fn htmlReadme(a: Allocator, readme: []const u8) ![]HTML.E {
    var dom = DOM.new(a);

    dom = dom.open(HTML.element("readme", null, null));
    dom.push(HTML.element("intro", "README.md", null));
    dom = dom.open(HTML.element("code", null, null));
    var litr = std.mem.split(u8, readme, "\n");
    while (litr.next()) |dirty| {
        var clean = try a.alloc(u8, dirty.len * 2);
        clean = Bleach.sanitize(dirty, clean, .{}) catch return error.Unknown;
        dom.push(HTML.element("ln", clean, null));
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
    obj: git.Blob,
    ch: git.ChangeSet,
) !*DOM {
    var dom = ddom;
    if (obj.isFile()) {
        dom = try drawBlob(a, dom, rname, base, obj);
    } else {
        dom = try drawTree(a, dom, rname, base, obj);
    }

    // I know... I KNOW!!!
    dom = dom.open(HTML.div(null, null));
    const commit_href = try aPrint(a, "/repo/{s}/commit/{s}", .{ rname, ch.sha[0..8] });
    dom.push(try HTML.aHrefAlloc(a, ch.commit_title, commit_href));
    dom.dupe(HTML.span(try aPrint(a, "{}", .{Humanize.unix(ch.timestamp)}), null));
    dom = dom.close();
    return dom.close();
}

fn drawBlob(a: Allocator, ddom: *DOM, rname: []const u8, base: []const u8, obj: git.Blob) !*DOM {
    var dom = ddom.open(HTML.element("file", null, null));
    const file_link = try aPrint(a, "/repo/{s}/blob/{s}{s}", .{ rname, base, obj.name });

    const href = &[_]HTML.Attribute{.{
        .key = "href",
        .value = file_link,
    }};
    dom.dupe(HTML.anch(obj.name, href));

    return dom;
}

fn drawTree(a: Allocator, ddom: *DOM, rname: []const u8, base: []const u8, obj: git.Blob) !*DOM {
    var dom = ddom.open(HTML.element("tree", null, null));
    const file_link = try aPrint(a, "/repo/{s}/tree/{s}{s}/", .{ rname, base, obj.name });

    const href = &[_]HTML.Attribute{.{
        .key = "href",
        .value = file_link,
    }};
    dom.dupe(HTML.anch(try dupeDir(a, obj.name), href));
    return dom;
}

fn tree(ctx: *Context, repo: *git.Repo, files: *git.Tree) Error!void {
    var tmpl = Template.find("repo.html");
    tmpl.init(ctx.alloc);

    const head = if (repo.head) |h| switch (h) {
        .sha => |s| s,
        .branch => |b| b.name,
        else => "unknown",
    } else "unknown";
    tmpl.addVar("branch.default", head) catch return error.Unknown;

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
    const branches = try aPrint(ctx.alloc, "{} branches", .{repo.refs.len});
    dom.push(HTML.span(branches, null));

    const c = repo.commit(ctx.alloc) catch return error.Unknown;
    dom.push(HTML.span(c.title[0..@min(c.title.len, 50)], null));
    const commit_time = try aPrint(ctx.alloc, "  {}", .{Humanize.unix(c.committer.timestamp)});
    dom = dom.open(HTML.span(null, &HTML.Attr.class("muted")));
    const commit_href = try aPrint(ctx.alloc, "/repo/{s}/commit/{s}", .{ rd.name, c.sha[0..8] });
    dom.push(HTML.text(commit_time));
    dom.push(try HTML.aHrefAlloc(ctx.alloc, c.sha[0..8], commit_href));
    dom = dom.close();
    dom = dom.close();

    dom = dom.open(HTML.div(null, &HTML.Attr.class("treelist")));
    if (uri_base.len > 0) {
        const end = std.mem.lastIndexOf(u8, uri_base[0 .. uri_base.len - 1], "/") orelse 0;
        dom = dom.open(HTML.element("tree", null, null));
        const dd_href = &[_]HTML.Attribute{.{
            .key = "href",
            .value = try aPrint(
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
        std.sort.pdq(git.Blob, files.objects, {}, typeSorter);
        for (files.objects) |obj| {
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
    const data = dom.done();
    _ = tmpl.addElements(ctx.alloc, "repo", data) catch return error.Unknown;

    for (files.objects) |obj| {
        if (isReadme(obj.name)) {
            var resolve = repo.blob(ctx.alloc, &obj.hash) catch return error.Unknown;
            var reader = resolve.reader();
            const readme_txt = reader.readAllAlloc(ctx.alloc, 0xffffff) catch unreachable;
            const readme = htmlReadme(ctx.alloc, readme_txt) catch unreachable;
            _ = tmpl.addElementsFmt(ctx.alloc, "{pretty}", "readme", readme) catch return error.Unknown;
            break;
        }
    }

    ctx.sendTemplate(&tmpl) catch return error.Unknown;
}
// this is the end
