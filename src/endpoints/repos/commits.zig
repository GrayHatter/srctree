const std = @import("std");

const Allocator = std.mem.Allocator;

const Repos = @import("../repos.zig");
const Endpoint = @import("../../endpoint.zig");

const Response = Endpoint.Response;
const Context = Endpoint.Context;
const HTML = Endpoint.HTML;
const DOM = Endpoint.DOM;
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;
const RouteData = Repos.RouteData;
const ROUTE = Endpoint.Router.ROUTE;
const GET = Endpoint.Router.GET;

const git = @import("../../git.zig");
const Bleach = @import("../../bleach.zig");
const Patch = @import("../../patch.zig");
const CmmtMap = Endpoint.Types.CommitMap;
const Comment = Endpoint.Types.Comment;

const POST = Endpoint.Router.Methods.POST;

pub const routes = [_]Endpoint.Router.MatchRouter{
    ROUTE("", commits),
    GET("before", commitsBefore),
};

pub fn router(ctx: *Context) Error!Endpoint.Router.Callable {
    const rd = RouteData.make(&ctx.uri) orelse return commits;
    if (rd.verb != null and std.mem.eql(u8, "commit", rd.verb.?))
        return commit;
    return commits;
}

fn addComment(a: Allocator, c: Comment) ![]HTML.Element {
    var dom = DOM.new(a);
    dom = dom.open(HTML.element("comment", null, null));

    dom = dom.open(HTML.element("context", null, null));
    dom.dupe(HTML.element(
        "author",
        &[_]HTML.E{HTML.text(Bleach.sanitizeAlloc(a, c.author, .{}) catch unreachable)},
        null,
    ));
    dom.push(HTML.element("date", "now", null));
    dom = dom.close();

    dom = dom.open(HTML.element("message", null, null));
    dom.push(HTML.text(Bleach.sanitizeAlloc(a, c.message, .{}) catch unreachable));
    dom = dom.close();

    dom = dom.close();
    return dom.done();
}

pub fn patchHtml(a: Allocator, patch: []const u8) ![]HTML.Element {
    var p = Patch.Patch.init(patch);
    const files = p.filesSlice(a) catch return &[0]HTML.Element{};
    defer a.free(files);

    var dom = DOM.new(a);

    dom = dom.open(HTML.patch());
    for (files) |diff| {
        var h = Patch.Header{ .data = diff };
        h.parse() catch |e| {
            std.debug.print("error {}\n", .{e});
            std.debug.print("patch {s}\n", .{diff});
            continue;
        };
        const body = h.changes orelse continue;

        const dstat = p.diffstat();
        const stat = try std.fmt.allocPrint(a, "added: {}, removed: {}, total {}", .{
            dstat.additions,
            dstat.deletions,
            dstat.total,
        });
        dom.push(HTML.element("diffstat", stat, null));
        dom = dom.open(HTML.diff());
        dom.push(HTML.element("filename", h.filename.right orelse "File Deleted", null));
        dom = dom.open(HTML.element("changes", null, null));
        dom.pushSlice(Patch.diffLine(a, body));
        dom = dom.close();
        dom = dom.close();
    }
    dom = dom.close();
    return dom.done();
}

fn commitHtml(ctx: *Context, sha: []const u8, repo_name: []const u8, repo: git.Repo) Error!void {
    var tmpl = Template.find("commit.html");
    tmpl.init(ctx.alloc);

    if (!git.commitish(sha)) {
        std.debug.print("Abusive ''{s}''\n", .{sha});
        return error.Abusive;
    }

    var dom = DOM.new(ctx.alloc);
    const current: git.Commit = repo.commit(ctx.alloc, sha) catch cmt: {
        // TODO return 404
        var fallback: git.Commit = repo.headCommit(ctx.alloc) catch return error.Unknown;
        while (!std.mem.startsWith(u8, fallback.sha, sha)) {
            fallback = fallback.toParent(ctx.alloc, 0) catch return error.Unknown;
        }
        break :cmt fallback;
    };
    dom.pushSlice(try htmlCommit(ctx.alloc, current, repo_name, true));

    var acts = repo.getActions(ctx.alloc);
    var diff = acts.show(sha) catch return error.Unknown;
    if (std.mem.indexOf(u8, diff, "diff")) |i| {
        diff = diff[i..];
    }
    _ = tmpl.addElements(ctx.alloc, "Commits", dom.done()) catch return error.Unknown;

    var diff_dom = DOM.new(ctx.alloc);
    diff_dom = diff_dom.open(HTML.element("diff", null, null));
    diff_dom = diff_dom.open(HTML.element("patch", null, null));
    diff_dom.pushSlice(try patchHtml(ctx.alloc, diff));
    diff_dom = diff_dom.close();
    diff_dom = diff_dom.close();
    _ = tmpl.addElementsFmt(ctx.alloc, "{pretty}", "Diff", diff_dom.done()) catch return error.Unknown;

    var comments = DOM.new(ctx.alloc);
    //for ([_]Comment{ .{
    //    .author = "robinli",
    //    .message = "Woah, I didn't know srctree had the ability to comment on commits!",
    //}, .{
    //    .author = "grayhatter",
    //    .message = "Hah, yeah, added it the other day... pretty dope huh?",
    //} }) |cm| {
    //    comments.pushSlice(addComment(ctx.alloc, cm) catch unreachable);
    //}

    const map = CmmtMap.open(ctx.alloc, sha) catch unreachable;
    for (map.comments) |cm| {
        comments.pushSlice(addComment(ctx.alloc, cm) catch unreachable);
    }

    _ = try tmpl.addElements(ctx.alloc, "Comments", comments.done());

    var opengraph = [_]Template.Context{
        Template.Context.init(ctx.alloc),
    };

    opengraph[0].putSimple("Title", "Commit") catch return error.Unknown;
    try opengraph[0].putSimple("Desc", Bleach.sanitizeAlloc(ctx.alloc, current.message, .{}) catch unreachable);
    try ctx.putContext("OpenGraph", .{ .block = opengraph[0..] });

    ctx.response.status = .ok;
    return ctx.sendTemplate(&tmpl) catch unreachable;
}

pub fn commitPatch(ctx: *Context, sha: []const u8, repo: git.Repo) Error!void {
    var current: git.Commit = repo.headCommit(ctx.alloc) catch return error.Unknown;
    var acts = repo.getActions(ctx.alloc);
    if (std.mem.indexOf(u8, sha, ".patch")) |tail| {
        while (!std.mem.startsWith(u8, current.sha, sha[0..tail])) {
            current = current.toParent(ctx.alloc, 0) catch return error.Unknown;
        }

        var diff = acts.show(sha[0..tail]) catch return error.Unknown;
        if (std.mem.indexOf(u8, diff, "diff")) |i| {
            diff = diff[i..];
        }
        ctx.response.status = .ok;
        ctx.response.headersAdd("Content-Type", "text/x-patch") catch unreachable; // Firefox is trash
        ctx.response.start() catch return Error.Unknown;
        ctx.response.send(diff) catch return Error.Unknown;
        ctx.response.finish() catch return Error.Unknown;
    }
}

pub fn commit(ctx: *Context) Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    if (rd.verb == null) return commits(ctx);

    const sha = rd.noun orelse return error.Unrouteable;
    if (std.mem.indexOf(u8, sha, ".") != null and !std.mem.endsWith(u8, sha, ".patch")) return error.Unrouteable;
    const cwd = std.fs.cwd();
    // FIXME user data flows into system
    const filename = try std.fmt.allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    const dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;
    defer repo.raze(ctx.alloc);

    if (std.mem.endsWith(u8, sha, ".patch"))
        return commitPatch(ctx, sha, repo)
    else
        return commitHtml(ctx, sha, rd.name, repo);
    return error.Unrouteable;
}

pub fn htmlCommit(a: Allocator, c: git.Commit, repo: []const u8, comptime top: bool) ![]HTML.E {
    var dom = DOM.new(a);
    dom = dom.open(HTML.element("commit", null, null));

    var cd_dom = DOM.new(a);
    cd_dom = cd_dom.open(HTML.element("data", null, null));
    cd_dom.push(try HTML.aHrefAlloc(
        a,
        c.sha[0..8],
        try std.fmt.allocPrint(a, "/repo/{s}/commit/{s}", .{ repo, c.sha[0..8] }),
    ));
    cd_dom.push(HTML.br());
    cd_dom.push(HTML.text(Bleach.sanitizeAlloc(a, c.title, .{}) catch unreachable));
    if (c.body.len > 0) {
        cd_dom.push(HTML.br());
        cd_dom.push(HTML.text(Bleach.sanitizeAlloc(a, c.body, .{}) catch unreachable));
    }
    cd_dom = cd_dom.close();
    const cdata = cd_dom.done();

    if (!top) dom.pushSlice(cdata);

    dom = dom.open(HTML.element(if (top) "top" else "foot", null, null));
    {
        const prnt = c.parent[0] orelse "00000000";
        dom.push(HTML.element("author", try a.dupe(u8, c.author.name), null));
        dom = dom.open(HTML.span(null, null));
        dom.push(HTML.text("parent "));
        dom.push(try HTML.aHrefAlloc(
            a,
            prnt[0..8],
            try std.fmt.allocPrint(a, "/repo/{s}/commit/{s}", .{ repo, prnt[0..8] }),
        ));
        dom = dom.close();
    }
    dom = dom.close();

    if (top) dom.pushSlice(cdata);

    dom = dom.close();
    return dom.done();
}

fn commitContext(a: Allocator, c: git.Commit, repo: []const u8, comptime _: bool) !Template.Context {
    var ctx = Template.Context.init(a);

    try ctx.put("Sha", c.sha[0..8]);
    try ctx.put("Uri", try std.fmt.allocPrint(a, "/repo/{s}/commit/{s}", .{ repo, c.sha[0..8] }));
    // TODO handle error.NotImplemented
    try ctx.put("Msg_title", Bleach.sanitizeAlloc(a, c.title, .{}) catch unreachable);
    try ctx.put("Msg", Bleach.sanitizeAlloc(a, c.body, .{}) catch unreachable);
    //if (top) "top" else "foot", null, null));
    const parent = c.parent[0] orelse "00000000";
    try ctx.put("Author", c.author.name);
    try ctx.put("Parent", parent[0..8]);
    try ctx.put("Parent_uri", try std.fmt.allocPrint(a, "/repo/{s}/commit/{s}", .{ repo, parent[0..8] }));
    return ctx;
}

fn buildList(
    a: Allocator,
    repo: git.Repo,
    name: []const u8,
    before: ?[]const u8,
    elms: []Template.Context,
    sha: []u8,
) ![]Template.Context {
    return buildListBetween(a, repo, name, null, before, elms, sha);
}

fn buildListBetween(
    a: Allocator,
    repo: git.Repo,
    name: []const u8,
    left: ?[]const u8,
    right: ?[]const u8,
    elms: []Template.Context,
    sha: []u8,
) ![]Template.Context {
    var current: git.Commit = repo.headCommit(a) catch return error.Unknown;
    if (right) |r| {
        std.debug.assert(r.len <= 40);
        const min = @min(r.len, current.sha.len);
        while (!std.mem.eql(u8, r, current.sha[0..min])) {
            current = current.toParent(a, 0) catch {
                std.debug.print("unable to build commit history\n", .{});
                return elms[0..0];
            };
        }
        current = current.toParent(a, 0) catch {
            std.debug.print("unable to build commit history\n", .{});
            return elms[0..0];
        };
    }
    var count: usize = 0;
    for (elms, 1..) |*c, i| {
        count = i;
        @memcpy(sha, current.sha[0..8]);
        c.* = try commitContext(a, current, name, false);
        if (left) |l| {
            const min = @min(l.len, current.sha.len);
            if (std.mem.eql(u8, l, current.sha[0..min])) break;
        }
        current = current.toParent(a, 0) catch {
            break;
        };
    }
    return elms[0..count];
}

pub fn commits(ctx: *Context) Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;

    const commitish = rd.noun;
    if (commitish) |cmish| {
        std.debug.print("{s}\n", .{cmish});
        if (!git.commitish(cmish)) return error.Unrouteable;
        if (std.mem.indexOf(u8, cmish, "..")) |i| {
            const left = cmish[0..i];
            if (!git.commitish(left)) return error.Unrouteable;
            const right = cmish[i + 2 ..];
            if (!git.commitish(right)) return error.Unrouteable;

            std.debug.print("{s}, {s}\n", .{ left, right });
        }
    } else {}

    const filename = try std.fmt.allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    var cwd = std.fs.cwd();
    const dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;
    defer repo.raze(ctx.alloc);

    const commits_b = try ctx.alloc.alloc(Template.Context, 50);
    var last_sha: [8]u8 = undefined;
    const cmts_list = try buildList(ctx.alloc, repo, rd.name, null, commits_b, &last_sha);

    const before_txt = try std.fmt.allocPrint(ctx.alloc, "/repo/{s}/commits/before/{s}", .{ rd.name, last_sha });
    return sendCommits(ctx, cmts_list, before_txt);
}

pub fn commitsBefore(ctx: *Context) Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;

    std.debug.assert(std.mem.eql(u8, "after", ctx.uri.next().?));

    const filename = try std.fmt.allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    var cwd = std.fs.cwd();
    const dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;

    const before = ctx.uri.next();
    const commits_b = try ctx.alloc.alloc(Template.Context, 50);
    var last_sha: [8]u8 = undefined;
    const cmts_list = try buildList(ctx.alloc, repo, rd.name, before, commits_b, &last_sha);
    const before_txt = try std.fmt.allocPrint(ctx.alloc, "/repo/{s}/commits/before/{s}", .{ rd.name, last_sha });
    return sendCommits(ctx, cmts_list, before_txt);
}

fn sendCommits(ctx: *Context, list: []Template.Context, before_txt: []const u8) Error!void {
    var tmpl = Template.find("commits.html");
    tmpl.init(ctx.alloc);

    try tmpl.ctx.?.putBlock("Commits", list);

    _ = tmpl.addElements(ctx.alloc, "After", &[_]HTML.E{
        try HTML.linkBtnAlloc(ctx.alloc, "More", before_txt),
    }) catch return error.Unknown;

    ctx.response.status = .ok;
    ctx.sendTemplate(&tmpl) catch return error.Unknown;
}
