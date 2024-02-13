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

const git = @import("../../git.zig");
const Bleach = @import("../../bleach.zig");
const Patch = @import("../../patch.zig");
const CmmtMap = @import("../../types/commit-notes.zig");
const Comments = Endpoint.Types.Comments;
const Comment = Comments.Comment;

const GET = Endpoint.Router.Methods.GET;
const POST = Endpoint.Router.Methods.POST;

pub const routes = [_]Endpoint.Router.MatchRouter{
    .{ .name = "", .methods = GET, .match = .{ .call = commits } },
    .{ .name = "after", .methods = GET, .match = .{ .call = commitsAfter } },
};

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

fn commitHtml(ctx: *Context, sha: []const u8, repo_name: []const u8, repo: git.Repo) Error!void {
    var tmpl = Template.find("commit.html");
    tmpl.init(ctx.alloc);

    if (!git.commitish(sha)) {
        std.debug.print("Abusive ''{s}''\n", .{sha});
        return error.Abusive;
    }

    var dom = DOM.new(ctx.alloc);
    var current: git.Commit = repo.commit(ctx.alloc) catch return error.Unknown;
    while (!std.mem.startsWith(u8, current.sha, sha)) {
        current = current.toParent(ctx.alloc, 0) catch return error.Unknown;
    }
    dom.pushSlice(try htmlCommit(ctx.alloc, current, repo_name, true));

    var acts = repo.getActions(ctx.alloc);
    var diff = acts.show(sha) catch return error.Unknown;
    if (std.mem.indexOf(u8, diff, "diff")) |i| {
        diff = diff[i..];
    }
    _ = tmpl.addElements(ctx.alloc, "commits", dom.done()) catch return error.Unknown;

    var diff_dom = DOM.new(ctx.alloc);
    diff_dom = diff_dom.open(HTML.element("diff", null, null));
    diff_dom = diff_dom.open(HTML.element("patch", null, null));
    diff_dom.pushSlice(try Patch.patchHtml(ctx.alloc, diff));
    diff_dom = diff_dom.close();
    diff_dom = diff_dom.close();
    _ = tmpl.addElementsFmt(ctx.alloc, "{pretty}", "diff", diff_dom.done()) catch return error.Unknown;

    var comments = DOM.new(ctx.alloc);
    for ([_]Comment{ .{
        .author = "robinli",
        .message = "Woah, I didn't know srctree had the ability to comment on commits!",
    }, .{
        .author = "grayhatter",
        .message = "Hah, yeah, added it the other day... pretty dope huh?",
    } }) |cm| {
        comments.pushSlice(addComment(ctx.alloc, cm) catch unreachable);
    }

    var map = CmmtMap.open(ctx.alloc, sha) catch unreachable;
    for (map.comments) |cm| {
        comments.pushSlice(addComment(ctx.alloc, cm) catch unreachable);
    }

    _ = try tmpl.addElements(ctx.alloc, "comments", comments.done());

    ctx.response.status = .ok;
    return ctx.sendTemplate(&tmpl) catch unreachable;
}

pub fn commitPatch(ctx: *Context, sha: []const u8, repo: git.Repo) Error!void {
    var current: git.Commit = repo.commit(ctx.alloc) catch return error.Unknown;
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
    var cwd = std.fs.cwd();
    // FIXME user data flows into system
    var filename = try std.fmt.allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;

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
    cd_dom.push(HTML.text(c.message));
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

    try ctx.put("sha", c.sha[0..8]);
    try ctx.put("uri", try std.fmt.allocPrint(a, "/repo/{s}/commit/{s}", .{ repo, c.sha[0..8] }));
    if (std.mem.indexOf(u8, c.message, "\n\n")) |i| {
        try ctx.put("msg_title", c.message[0..i]);
        try ctx.put("msg", c.message[i + 2 ..]);
    } else {
        try ctx.put("msg", c.message);
    }

    //if (top) "top" else "foot", null, null));
    const parent = c.parent[0] orelse "00000000";
    try ctx.put("author", c.author.name);
    try ctx.put("parent", parent[0..8]);
    try ctx.put("parent_uri", try std.fmt.allocPrint(a, "/repo/{s}/commit/{s}", .{ repo, parent[0..8] }));
    return ctx;
}

fn commitsList(
    a: Allocator,
    repo: git.Repo,
    name: []const u8,
    after: ?[]const u8,
    elms: []Template.Context,
    sha: []u8,
) ![]Template.Context {
    var current: git.Commit = repo.commit(a) catch return error.Unknown;
    if (after) |aft| {
        std.debug.assert(aft.len <= 40);
        var min = @min(aft.len, current.sha.len);
        while (!std.mem.eql(u8, aft, current.sha[0..min])) {
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
        current = current.toParent(a, 0) catch {
            break;
        };
    }
    return elms[0..count];
}

pub fn commits(ctx: *Context) Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;

    var filename = try std.fmt.allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    var cwd = std.fs.cwd();
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;

    const after = null;
    var commits_b = try ctx.alloc.alloc(Template.Context, 50);
    var last_sha: [8]u8 = undefined;
    const cmts_list = try commitsList(ctx.alloc, repo, rd.name, after, commits_b, &last_sha);

    var tmpl = Template.find("commits.html");
    tmpl.init(ctx.alloc);

    try tmpl.ctx.?.putBlock("commits", cmts_list);

    const target = try std.fmt.allocPrint(ctx.alloc, "/repo/{s}/commits/after/{s}", .{ rd.name, last_sha });
    _ = tmpl.addElements(ctx.alloc, "after", &[_]HTML.E{
        try HTML.linkBtnAlloc(ctx.alloc, "More", target),
    }) catch return error.Unknown;

    ctx.response.status = .ok;
    ctx.sendTemplate(&tmpl) catch return error.Unknown;
}

pub fn commitsAfter(ctx: *Context) Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;

    std.debug.assert(std.mem.eql(u8, "after", ctx.uri.next().?));

    var filename = try std.fmt.allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    var cwd = std.fs.cwd();
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;

    const after = ctx.uri.next();
    var commits_b = try ctx.alloc.alloc(Template.Context, 50);
    var last_sha: [8]u8 = undefined;
    const cmts_list = try commitsList(ctx.alloc, repo, rd.name, after, commits_b, &last_sha);

    var tmpl = Template.find("commits.html");
    tmpl.init(ctx.alloc);

    try tmpl.ctx.?.putBlock("commits", cmts_list);

    const target = try std.fmt.allocPrint(ctx.alloc, "/repo/{s}/commits/after/{s}", .{ rd.name, last_sha });
    _ = tmpl.addElements(ctx.alloc, "after", &[_]HTML.E{
        try HTML.linkBtnAlloc(ctx.alloc, "More", target),
    }) catch return error.Unknown;

    ctx.response.status = .ok;
    ctx.sendTemplate(&tmpl) catch return error.Unknown;
}
