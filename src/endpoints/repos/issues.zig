const std = @import("std");

const Allocator = std.mem.Allocator;

const DOM = Endpoint.DOM;
const HTML = Endpoint.HTML;
const Endpoint = @import("../../endpoint.zig");
const Context = @import("../../context.zig");
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;
const ROUTE = Endpoint.Router.ROUTE;
const POST = Endpoint.Router.POST;

const Repo = @import("../repos.zig");

const CURL = @import("../../curl.zig");
const Bleach = @import("../../bleach.zig");
const Comments = Endpoint.Types.Comments;
const Comment = Comments.Comment;
const Deltas = Endpoint.Types.Deltas;
const Humanize = @import("../../humanize.zig");

pub const routes = [_]Endpoint.Router.MatchRouter{
    ROUTE("", list),
    ROUTE("new", new),
    POST("new", newPost),
    POST("add-comment", newComment),
};

fn isHex(input: []const u8) ?usize {
    for (input) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return std.fmt.parseInt(usize, input, 16) catch null;
}

pub fn router(ctx: *Context) Error!Endpoint.Router.Callable {
    std.debug.assert(std.mem.eql(u8, "issues", ctx.uri.next().?));
    const verb = ctx.uri.peek() orelse return Endpoint.Router.router(ctx, &routes);

    if (isHex(verb)) |_| {
        return view;
    }

    return Endpoint.Router.router(ctx, &routes);
}

fn new(ctx: *Context) Error!void {
    var tmpl = comptime Template.find("issue-new.html");
    tmpl.init(ctx.alloc);
    try ctx.sendTemplate(&tmpl);
}

fn newPost(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    var buf: [2048]u8 = undefined;
    if (ctx.req_data.post_data) |post| {
        var valid = post.validator();
        const title = try valid.require("title");
        const msg = try valid.require("desc");
        var delta = Deltas.new(rd.name) catch unreachable;
        delta.title = title.value;
        delta.message = msg.value;
        delta.attach = .{ .issue = 0 };
        delta.writeOut() catch unreachable;

        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, delta.index });
        return ctx.response.redirect(loc, true) catch unreachable;
    }

    const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issue/new", .{rd.name});
    return ctx.response.redirect(loc, true) catch unreachable;
}

fn newComment(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    if (ctx.req_data.post_data) |post| {
        var valid = post.validator();
        const delta_id = try valid.require("did");
        const msg = try valid.require("comment");
        const issue_index = isHex(delta_id.value) orelse return error.Unrouteable;

        var delta = Deltas.open(
            ctx.alloc,
            rd.name,
            issue_index,
        ) catch unreachable orelse return error.Unrouteable;
        _ = delta.loadThread(ctx.alloc) catch unreachable;
        const username = if (ctx.auth.valid())
            (ctx.auth.user(ctx.alloc) catch unreachable).username
        else
            "public";
        const c = Comments.new(username, msg.value) catch unreachable;

        delta.addComment(ctx.alloc, c) catch {};
        delta.writeOut() catch unreachable;
        var buf: [2048]u8 = undefined;
        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, issue_index });
        ctx.response.redirect(loc, true) catch unreachable;
        return;
    }
    return error.Unknown;
}

fn view(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    const delta_id = ctx.uri.next().?;
    const index = isHex(delta_id) orelse return error.Unrouteable;

    var tmpl = Template.find("delta-issue.html");
    tmpl.init(ctx.alloc);

    var delta = (Deltas.open(ctx.alloc, rd.name, index) catch return error.Unrouteable) orelse return error.Unrouteable;
    try tmpl.ctx.?.put("repo", rd.name);
    //dom.push(HTML.text(delta.repo));

    try tmpl.ctx.?.put(
        "title",
        Bleach.sanitizeAlloc(ctx.alloc, delta.title, .{}) catch unreachable,
    );

    try tmpl.ctx.?.put(
        "desc",
        Bleach.sanitizeAlloc(ctx.alloc, delta.message, .{}) catch unreachable,
    );

    _ = delta.loadThread(ctx.alloc) catch unreachable;
    if (delta.getComments(ctx.alloc)) |cm| {
        const comments: []Template.Context = try ctx.alloc.alloc(Template.Context, cm.len);

        for (cm, comments) |comment, *cctx| {
            cctx.* = Template.Context.init(ctx.alloc);
            const builder = comment.builder();
            builder.build(ctx.alloc, cctx) catch unreachable;
            try cctx.put(
                "date",
                try std.fmt.allocPrint(ctx.alloc, "{}", .{Humanize.unix(comment.updated)}),
            );
        }
        try tmpl.ctx.?.putBlock("comments", comments);
    } else |err| {
        std.debug.print("Unable to load comments for thread {} {}\n", .{ index, err });
        @panic("oops");
    }

    try tmpl.ctx.?.put("delta_id", delta_id);

    try ctx.sendTemplate(&tmpl);
}

fn list(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;

    const last = Deltas.last(rd.name) + 1;
    var end: usize = 0;

    var tmpl_ctx = try ctx.alloc.alloc(Template.Context, last);
    for (0..last) |i| {
        var d = Deltas.open(ctx.alloc, rd.name, i) catch continue orelse continue;
        if (!std.mem.eql(u8, d.repo, rd.name) or d.attach != .issue) {
            d.raze(ctx.alloc);
            continue;
        }

        const delta_ctx = &tmpl_ctx[end];
        delta_ctx.* = Template.Context.init(ctx.alloc);
        const builder = d.builder();
        builder.build(ctx.alloc, delta_ctx) catch unreachable;
        _ = d.loadThread(ctx.alloc) catch unreachable;
        if (d.getComments(ctx.alloc)) |cmts| {
            try delta_ctx.put(
                "comments_icon",
                try std.fmt.allocPrint(ctx.alloc, "<span class=\"icon\">\xee\xa0\x9c {}</span>", .{cmts.len}),
            );
        } else |_| unreachable;
        end += 1;
        continue;
    }
    var tmpl = Template.find("deltalist.html");
    tmpl.init(ctx.alloc);
    try tmpl.ctx.?.putBlock("list", tmpl_ctx[0..end]);

    var default_search_buf: [0xFF]u8 = undefined;
    const def_search = try std.fmt.bufPrint(&default_search_buf, "is:issue repo:{s} ", .{rd.name});
    try tmpl.ctx.?.put("search", def_search);

    try ctx.sendTemplate(&tmpl);
}
