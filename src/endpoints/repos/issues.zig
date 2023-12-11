const std = @import("std");

const Allocator = std.mem.Allocator;

const DOM = Endpoint.DOM;
const HTML = Endpoint.HTML;
const Endpoint = @import("../../endpoint.zig");
const Context = @import("../../context.zig");
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;

const Repo = @import("../repos.zig");

const GET = Endpoint.Router.Methods.GET;
const POST = Endpoint.Router.Methods.POST;

const CURL = @import("../../curl.zig");
const Bleach = @import("../../bleach.zig");
const Issues = Endpoint.Types.Issues;
const Comments = Endpoint.Types.Comments;
const Comment = Comments.Comment;

pub const routes = [_]Endpoint.Router.MatchRouter{
    .{ .name = "", .methods = GET, .match = .{ .call = list } },
    .{ .name = "new", .methods = GET, .match = .{ .call = new } },
    .{ .name = "new", .methods = POST, .match = .{ .call = newPost } },
    .{ .name = "add-comment", .methods = POST, .match = .{ .call = newComment } },
};

fn isHex(input: []const u8) ?usize {
    for (input) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return std.fmt.parseInt(usize, input, 16) catch null;
}

fn issueValidForRepo(repo: []const u8, issue: usize) bool {
    _ = repo;
    return issue > 0;
}

pub fn router(ctx: *Context) Error!Endpoint.Router.Callable {
    std.debug.assert(std.mem.eql(u8, "issues", ctx.uri.next().?));
    const verb = ctx.uri.peek() orelse return Endpoint.Router.router(ctx, &routes);

    const repo_name = "none";
    if (isHex(verb)) |dnum| {
        if (issueValidForRepo(repo_name, dnum))
            return view;
    }

    return Endpoint.Router.router(ctx, &routes);
}

fn new(ctx: *Context) Error!void {
    var tmpl = comptime Template.find("issue-new.html");
    tmpl.init(ctx.alloc);
    ctx.sendTemplate(&tmpl) catch unreachable;
}

fn inNetwork(str: []const u8) bool {
    if (!std.mem.startsWith(u8, str, "https://srctree.gr.ht")) return false;
    for (str) |c| if (c == '@') return false;
    return true;
}

fn newPost(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    if (ctx.response.usr_data) |usrdata| if (usrdata.post_data) |post| {
        var valid = post.validator();
        const title = try valid.require("title");
        const msg = try valid.require("message");
        var issue = Issues.new(rd.name, title.value, msg.value) catch unreachable;
        issue.writeOut() catch unreachable;
    };

    var tmpl = Template.find("issues.html");
    tmpl.init(ctx.alloc);
    try tmpl.addVar("issue", "new data attempting");
    ctx.sendTemplate(&tmpl) catch unreachable;
}

fn newComment(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    if (ctx.response.usr_data) |usrdata| if (usrdata.post_data) |post| {
        var valid = post.validator();
        const issue_id = try valid.require("issue-id");
        const msg = try valid.require("comment");
        const issue_index = isHex(issue_id.value) orelse return error.Unrouteable;

        var issue = Issues.open(ctx.alloc, issue_index) catch unreachable orelse return error.Unrouteable;
        var c = Comments.new("name", msg.value) catch unreachable;

        issue.addComment(ctx.alloc, c) catch {};
        issue.writeOut() catch unreachable;
        var buf: [2048]u8 = undefined;
        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, issue_index });
        ctx.response.redirect(loc, true) catch unreachable;
        return;
    };
    return error.Unknown;
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

fn view(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    const issue_target = ctx.uri.next().?;
    const index = isHex(issue_target) orelse return error.Unrouteable;

    var tmpl = Template.find("issue.html");
    tmpl.init(ctx.alloc);

    var dom = DOM.new(ctx.alloc);

    var issue = (Issues.open(ctx.alloc, index) catch return error.Unrouteable) orelse return error.Unrouteable;
    dom.push(HTML.text(rd.name));
    dom.push(HTML.text(issue.repo));
    dom.push(HTML.text(Bleach.sanitizeAlloc(ctx.alloc, issue.title, .{}) catch unreachable));
    dom.push(HTML.text(Bleach.sanitizeAlloc(ctx.alloc, issue.desc, .{}) catch unreachable));

    var comments = DOM.new(ctx.alloc);
    for ([_]Comment{ .{
        .author = "grayhatter",
        .message = "Wow, srctree's issue view looks really good!",
    }, .{
        .author = "robinli",
        .message = "I know, it's clearly the best I've even seen. Soon It'll even look good in Hastur!",
    } }) |cm| {
        comments.pushSlice(addComment(ctx.alloc, cm) catch unreachable);
    }
    for (issue.getComments(ctx.alloc) catch unreachable) |cm| {
        comments.pushSlice(addComment(ctx.alloc, cm) catch unreachable);
    }

    _ = try tmpl.addElements(ctx.alloc, "comments", comments.done());

    _ = try tmpl.addElements(ctx.alloc, "patch_header", dom.done());

    const hidden = [_]HTML.Attr{
        .{ .key = "type", .value = "hidden" },
        .{ .key = "name", .value = "issue-id" },
        .{ .key = "value", .value = issue_target },
    };

    const form_data = [_]HTML.E{
        HTML.input(&hidden),
    };

    _ = try tmpl.addElements(ctx.alloc, "form-data", &form_data);

    ctx.sendTemplate(&tmpl) catch unreachable;
}

fn issueRow(a: Allocator, issue: Issues.Issue) ![]HTML.Element {
    var dom = DOM.new(a);

    dom = dom.open(HTML.element("issue", null, null));
    const title = try Bleach.sanitizeAlloc(a, issue.title, .{ .rules = .title });
    const desc = try Bleach.sanitizeAlloc(a, issue.desc, .{});
    const href = try std.fmt.allocPrint(a, "{x}", .{issue.index});

    dom.push(try HTML.aHrefAlloc(a, title, href));
    dom.dupe(HTML.element("desc", desc, &HTML.Attr.class("muted")));
    dom = dom.close();

    return dom.done();
}

fn list(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    var dom = DOM.new(ctx.alloc);

    for (0..Issues.last() catch return error.Unknown) |i| {
        var d = Issues.open(ctx.alloc, i) catch continue orelse continue;
        defer d.raze(ctx.alloc);
        if (!std.mem.eql(u8, d.repo, rd.name)) continue;
        dom.pushSlice(issueRow(ctx.alloc, d) catch continue);
    }
    const issues = dom.done();
    var tmpl = comptime Template.find("actionable.html");
    tmpl.init(ctx.alloc);
    _ = try tmpl.addElements(ctx.alloc, "actionable_list", issues);
    ctx.sendTemplate(&tmpl) catch return error.Unknown;
}
