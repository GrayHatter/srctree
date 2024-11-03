const std = @import("std");

const Allocator = std.mem.Allocator;
const aPrint = std.fmt.allocPrint;
const bPrint = std.fmt.bufPrint;

const Context = @import("../context.zig");
const Response = @import("../response.zig");
const Request = @import("../request.zig");
const HTML = @import("../html.zig");
const elm = HTML.element;
const DOM = @import("../dom.zig");
const Template = @import("../template.zig");
const Route = @import("../routes.zig");
const Error = Route.Error;
const UriIter = Route.UriIter;
const ROUTE = Route.ROUTE;
const POST = Route.POST;
const GET = Route.GET;

const Bleach = @import("../bleach.zig");
const Humanize = @import("../humanize.zig");
const Ini = @import("../ini.zig");
const Repos = @import("../repos.zig");
const Git = @import("../git.zig");
const Highlighting = @import("../syntax-highlight.zig");

const Commits = @import("repos/commits.zig");
const Diffs = @import("repos/diffs.zig");
const Issues = @import("repos/issues.zig");
const commit = Commits.commit;
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
    ROUTE("tags", tags),
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

fn navButtons(ctx: *Context) ![2]Template.Structs.Navbuttons {
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

    const btns = [2]Template.Structs.Navbuttons{
        .{
            .name = "issues",
            .extra = try aPrint(ctx.alloc, "{}", .{i_count}),
            .url = try aPrint(ctx.alloc, "/repos/{s}/issues/", .{rd.name}),
        },
        .{
            .name = "diffs",
            .extra = try aPrint(ctx.alloc, "{}", .{d_count}),
            .url = try aPrint(ctx.alloc, "/repos/{s}/diffs/", .{rd.name}),
        },
    };

    return btns;
}

pub fn router(ctx: *Context) Error!Route.Callable {
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

        try ctx.addRouteVar("Repo_name", rd.name);

        const issueurl = try std.fmt.allocPrint(ctx.alloc, "/repos/{s}/issues/", .{rd.name});
        const issuecnt = try std.fmt.allocPrint(ctx.alloc, "{}", .{i_count});
        const diffcnt = try std.fmt.allocPrint(ctx.alloc, "{}", .{d_count});
        const diffurl = try std.fmt.allocPrint(ctx.alloc, "/repos/{s}/diffs/", .{rd.name});
        const header_nav = try ctx.alloc.dupe(Template.Context, &[2]Template.Context{
            Template.Context.initWith(ctx.alloc, &[3]Template.Context.Pair{
                .{ .name = "Name", .value = "issues" },
                .{ .name = "Url", .value = issueurl },
                .{ .name = "Extra", .value = issuecnt },
            }) catch return error.OutOfMemory,
            Template.Context.initWith(ctx.alloc, &[3]Template.Context.Pair{
                .{ .name = "Name", .value = "diffs" },
                .{ .name = "Url", .value = diffurl },
                .{ .name = "Extra", .value = diffcnt },
            }) catch return error.OutOfMemory,
        });
        try ctx.putContext("NavButtons", .{ .block = header_nav });

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
};

fn repoSorterNew(ctx: repoctx, l: Git.Repo, r: Git.Repo) bool {
    return !repoSorter(ctx, l, r);
}

fn repoSorter(ctx: repoctx, l: Git.Repo, r: Git.Repo) bool {
    var lc = l.headCommit(ctx.alloc) catch return true;
    defer lc.raze();
    var rc = r.headCommit(ctx.alloc) catch return false;
    defer rc.raze();
    return sorter({}, lc.committer.timestr, rc.committer.timestr);
}

fn sorter(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

fn htmlRepoBlock(a: Allocator, pre_dom: *DOM, name: []const u8, repo: Git.Repo) !*DOM {
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

        if (repo.headCommit(a)) |cmt| {
            defer cmt.raze();
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
        var repos = std.ArrayList(Git.Repo).init(ctx.alloc);
        var itr = idir.iterate();
        while (itr.next() catch return Error.Unknown) |file| {
            if (file.kind != .directory and file.kind != .sym_link) continue;
            if (file.name[0] == '.') continue;
            const rdir = idir.openDir(file.name, .{}) catch continue;
            var rpo = Git.Repo.init(rdir) catch continue;
            rpo.loadData(ctx.alloc) catch return error.Unknown;
            rpo.repo_name = ctx.alloc.dupe(u8, file.name) catch null;
            try repos.append(rpo);
        }
        std.sort.heap(Git.Repo, repos.items, repoctx{ .alloc = ctx.alloc }, repoSorterNew);

        var dom = DOM.new(ctx.alloc);

        if (ctx.request.auth.valid()) {
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
        _ = ctx.addElements(ctx.alloc, "Repos", data) catch return Error.Unknown;

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

    ctx.putContext("Files", .{ .slice = "<h3>New Repo!</h3><p>Todo, add content here</p>" }) catch return error.Unknown;
    ctx.response.status = .ok;

    try ctx.sendTemplate(&tmpl);
}

fn treeBlob(ctx: *Context) Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    _ = ctx.uri.next();

    var cwd = std.fs.cwd();
    const filename = try aPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    const dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = Git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;
    defer repo.raze(ctx.alloc);

    if (Repos.hasUpstream(ctx.alloc, repo) catch return error.Unknown) |up| {
        var upstream = [_]Template.Context{
            Template.Context.init(ctx.alloc),
        };
        upstream[0].putSlice("URI", up) catch return error.Unknown;
        ctx.putContext("Upstream", .{ .block = upstream[0..] }) catch return error.Unknown;
    }

    var opengraph = [_]Template.Context{
        Template.Context.init(ctx.alloc),
    };

    opengraph[0].putSlice("Title", rd.name) catch return error.Unknown;
    var desc = repo.description(ctx.alloc) catch return error.Unknown;
    if (std.mem.startsWith(u8, desc, "Unnamed repository; edit this file")) {
        desc = try aPrint(ctx.alloc, "An Indescribable repo with {s} commits", .{"[todo count commits]"});
    }
    try opengraph[0].putSlice("Desc", desc);
    try ctx.putContext("OpenGraph", .{ .block = opengraph[0..] });

    const cmt = repo.headCommit(ctx.alloc) catch return newRepo(ctx);
    var files: Git.Tree = cmt.mkTree(ctx.alloc) catch return error.Unknown;
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
    var in_lines = std.mem.split(u8, blame_txt, "\n");
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

fn blame(ctx: *Context) Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    std.debug.assert(std.mem.eql(u8, rd.verb orelse "", "blame"));
    _ = ctx.uri.next();
    const blame_file = ctx.uri.rest();

    var cwd = std.fs.cwd();
    const fname = try aPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    const dir = cwd.openDir(fname, .{}) catch return error.Unknown;
    var repo = Git.Repo.init(dir) catch return error.Unknown;
    defer repo.raze(ctx.alloc);

    var actions = repo.getAgent(ctx.alloc);
    actions.cwd = cwd.openDir(fname, .{}) catch unreachable;
    const git_blame = actions.blame(blame_file) catch unreachable;

    const parsed = parseBlame(ctx.alloc, git_blame) catch unreachable;
    var source_lines = std.ArrayList(u8).init(ctx.alloc);
    for (parsed.lines) |line| {
        try source_lines.appendSlice(line.line);
        try source_lines.append('\n');
    }

    const formatted = if (Highlighting.Language.guessFromFilename(blame_file)) |lang| fmt: {
        var pre = try Highlighting.highlight(ctx.alloc, lang, source_lines.items);
        break :fmt pre[28..][0 .. pre.len - 38];
    } else Bleach.sanitizeAlloc(ctx.alloc, source_lines.items, .{}) catch return error.Unknown;

    var litr = std.mem.split(u8, formatted, "\n");
    for (parsed.lines) |*line| {
        if (litr.next()) |n| {
            line.line = n;
        } else {
            break;
        }
    }

    const tctx = try wrapLineNumbersBlame(ctx.alloc, parsed.lines, parsed.map);
    for (tctx) |*c| {
        try c.putSlice("Repo_name", rd.name);
    }

    var tmpl = Template.find("blame.html");

    try ctx.putContext("Blame_lines", .{ .block = tctx[0..] });

    ctx.response.status = .ok;

    try ctx.sendTemplate(&tmpl);
}

fn wrapLineNumbersBlame(
    a: Allocator,
    blames: []BlameLine,
    map: std.StringHashMap(BlameCommit),
) ![]Template.Context {
    var tctx = try a.alloc(Template.Context, blames.len);
    for (blames, 0..) |line, i| {
        var ctx = Template.Context.init(a);
        const bcommit = map.get(line.sha) orelse unreachable;
        try ctx.putSlice("Sha", bcommit.sha[0..8]);
        try ctx.putSlice("Author", Bleach.sanitizeAlloc(a, bcommit.author.name, .{}) catch unreachable);
        try ctx.putSlice("AuthorEmail", Bleach.sanitizeAlloc(a, bcommit.author.email, .{}) catch unreachable);
        try ctx.putSlice("Time", try Humanize.unix(bcommit.author.timestamp).printAlloc(a));
        const b = std.fmt.allocPrint(a, "#L{}", .{i + 1}) catch unreachable;
        try ctx.putSlice("Num", b[2..]);
        try ctx.putSlice("Id", b[1..]);
        try ctx.putSlice("Href", b);
        try ctx.putSlice("Line", line.line);
        tctx[i] = ctx;
    }
    return tctx;
}

fn wrapLineNumbers(a: Allocator, root_dom: *DOM, text: []const u8) !*DOM {
    var dom = root_dom;
    dom = dom.open(HTML.element("code", null, null));
    // TODO

    var i: usize = 0;
    var litr = std.mem.split(u8, text, "\n");
    while (litr.next()) |line| {
        var pbuf: [12]u8 = undefined;
        const b = std.fmt.bufPrint(&pbuf, "#L{}", .{i + 1}) catch unreachable;
        const attrs = try HTML.Attribute.alloc(
            a,
            &[_][]const u8{ "num", "id", "href" },
            &[_]?[]const u8{ b[2..], b[1..], b },
        );
        dom.push(HTML.element("ln", line, attrs));
        i += 1;
    }

    return dom.close();
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
    return true;
}

const BlobPage = Template.PageData("blob.html");

fn blob(ctx: *Context, repo: *Git.Repo, pfiles: Git.Tree) Error!void {
    var blb: Git.Blob = undefined;

    var files = pfiles;
    search: while (ctx.uri.next()) |bname| {
        for (files.objects) |obj| {
            if (std.mem.eql(u8, bname, obj.name)) {
                blb = obj;
                if (obj.isFile()) {
                    if (ctx.uri.next()) |_| return error.InvalidURI;
                    break :search;
                }
                files = Git.Tree.fromRepo(ctx.alloc, repo.*, &obj.hash) catch return error.Unknown;
                continue :search;
            }
        } else return error.InvalidURI;
    }

    var resolve = repo.blob(ctx.alloc, &blb.hash) catch return error.Unknown;
    var reader = resolve.reader();

    var formatted: []const u8 = undefined;

    const d2 = reader.readAllAlloc(ctx.alloc, 0xffffff) catch unreachable;

    if (Highlighting.Language.guessFromFilename(blb.name)) |lang| {
        const pre = try Highlighting.highlight(ctx.alloc, lang, d2);
        formatted = pre[28..][0 .. pre.len - 38];
    } else if (excludedExt(blb.name)) {
        formatted = "This file type is currently unsupported";
    } else {
        formatted = Bleach.sanitizeAlloc(ctx.alloc, d2, .{}) catch return error.Unknown;
    }

    var dom = DOM.new(ctx.alloc);
    dom = try wrapLineNumbers(ctx.alloc, dom, formatted);
    const data = dom.done();

    const filestr = try aPrint(
        ctx.alloc,
        "{pretty}",
        .{HTML.div(data, &HTML.Attr.class("code-block"))},
    );
    ctx.uri.reset();
    _ = ctx.uri.next();
    const uri_repo = ctx.uri.next() orelse return error.Unrouteable;
    _ = ctx.uri.next();
    const uri_filename = Bleach.sanitizeAlloc(ctx.alloc, ctx.uri.rest(), .{}) catch return error.Unknown;

    ctx.response.status = .ok;

    var btns = navButtons(ctx) catch return error.Unknown;

    var page = BlobPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .nav = .{ .nav_auth = undefined, .nav_buttons = &btns } },
        .repo = uri_repo,
        .uri_filename = uri_filename,
        .filename = blb.name,
        .blob = filestr,
    });

    try ctx.sendPage(&page);
}

fn mkTree(a: Allocator, repo: Git.Repo, uri: *UriIter, pfiles: Git.Tree) !Git.Tree {
    var files: Git.Tree = pfiles;
    if (uri.next()) |udir| for (files.objects) |obj| {
        if (std.mem.eql(u8, udir, obj.name)) {
            files = try Git.Tree.fromRepo(a, repo, &obj.hash);
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
        const clean = Bleach.sanitizeAlloc(a, dirty, .{}) catch return error.Unknown;
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
    const commit_href = try aPrint(a, "/repo/{s}/commit/{s}", .{ rname, ch.sha[0..8] });
    dom.push(try HTML.aHrefAlloc(a, ch.commit_title, commit_href));
    dom.dupe(HTML.span(try aPrint(a, "{}", .{Humanize.unix(ch.timestamp)}), null));
    dom = dom.close();
    return dom.close();
}

fn drawBlob(a: Allocator, ddom: *DOM, rname: []const u8, base: []const u8, obj: Git.Blob) !*DOM {
    var dom = ddom.open(HTML.element("file", null, null));
    const file_link = try aPrint(a, "/repo/{s}/blob/{s}{s}", .{ rname, base, obj.name });

    const href = &[_]HTML.Attribute{.{
        .key = "href",
        .value = file_link,
    }};
    dom.dupe(HTML.anch(obj.name, href));

    return dom;
}

fn drawTree(a: Allocator, ddom: *DOM, rname: []const u8, base: []const u8, obj: Git.Blob) !*DOM {
    var dom = ddom.open(HTML.element("tree", null, null));
    const file_link = try aPrint(a, "/repo/{s}/tree/{s}{s}/", .{ rname, base, obj.name });

    const href = &[_]HTML.Attribute{.{
        .key = "href",
        .value = file_link,
    }};
    dom.dupe(HTML.anch(try dupeDir(a, obj.name), href));
    return dom;
}

fn tree(ctx: *Context, repo: *Git.Repo, files: *Git.Tree) Error!void {
    var tmpl = Template.find("tree.html");

    const head = if (repo.head) |h| switch (h) {
        .sha => |s| s,
        .branch => |b| b.name,
        else => "unknown",
    } else "unknown";
    ctx.putContext("Branch.default", .{ .slice = head }) catch return error.Unknown;

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

    const c = repo.headCommit(ctx.alloc) catch return error.Unknown;
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
        std.sort.pdq(Git.Blob, files.objects, {}, typeSorter);
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
    _ = ctx.addElements(ctx.alloc, "Repo", data) catch return error.Unknown;

    for (files.objects) |obj| {
        if (isReadme(obj.name)) {
            var resolve = repo.blob(ctx.alloc, &obj.hash) catch return error.Unknown;
            var reader = resolve.reader();
            const readme_txt = reader.readAllAlloc(ctx.alloc, 0xffffff) catch unreachable;
            const readme = htmlReadme(ctx.alloc, readme_txt) catch unreachable;
            _ = ctx.addElementsFmt(ctx.alloc, "{pretty}", "Readme", readme) catch return error.Unknown;
            break;
        }
    }

    ctx.sendTemplate(&tmpl) catch return error.Unknown;
}

fn tags(ctx: *Context) Error!void {
    ctx.response.redirect("/", true) catch return error.Unrouteable;
}
