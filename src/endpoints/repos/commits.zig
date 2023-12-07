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

pub fn commits(ctx: *Context) Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;

    var filename = try std.fmt.allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    var cwd = std.fs.cwd();
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;

    var lcommits = try ctx.alloc.alloc(HTML.E, 50);
    var current: git.Commit = repo.commit(ctx.alloc) catch return error.Unknown;
    for (lcommits, 0..) |*c, i| {
        c.* = (try htmlCommit(ctx.alloc, current, rd.name, false))[0];
        current = current.toParent(ctx.alloc, 0) catch {
            lcommits.len = i;
            break;
        };
    }

    const htmlstr = try std.fmt.allocPrint(ctx.alloc, "{}", .{
        HTML.div(lcommits, null),
    });

    var tmpl = Template.find("commits.html");
    tmpl.init(ctx.alloc);
    tmpl.addVar("commits", htmlstr) catch return error.Unknown;

    var page = tmpl.buildFor(ctx.alloc, ctx) catch unreachable;

    ctx.response.status = .ok;
    ctx.response.start() catch return Error.Unknown;
    ctx.response.send(page) catch return Error.Unknown;
    ctx.response.finish() catch return Error.Unknown;
}
