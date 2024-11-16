const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;

const Route = @import("../../routes.zig");
const DOM = @import("../../dom.zig");
const HTML = @import("../../html.zig");
const Context = @import("../../context.zig");
const Template = @import("../../template.zig");
const Error = Route.Error;
const UriIter = Route.Error;
const ROUTE = Route.ROUTE;
const POST = Route.POST;
const S = Template.Structs;

const Repos = @import("../repos.zig");

const CURL = @import("../../curl.zig");
const Bleach = @import("../../bleach.zig");
const Types = @import("../../types.zig");
const Comment = Types.Comment;
const Delta = Types.Delta;
const Humanize = @import("../../humanize.zig");

pub const routes = [_]Route.Match{
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

pub fn router(ctx: *Context) Error!Route.Callable {
    std.debug.assert(std.mem.eql(u8, "issues", ctx.uri.next().?));
    const verb = ctx.uri.peek() orelse return Route.router(ctx, &routes);

    if (isHex(verb)) |_| {
        return view;
    }

    return Route.router(ctx, &routes);
}

fn new(ctx: *Context) Error!void {
    var tmpl = comptime Template.find("issue-new.html");
    try ctx.sendTemplate(&tmpl);
}

fn newPost(ctx: *Context) Error!void {
    const rd = Repos.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    var buf: [2048]u8 = undefined;
    if (ctx.reqdata.post) |post| {
        var valid = post.validator();
        const title = try valid.require("title");
        const msg = try valid.require("desc");
        var delta = Delta.new(rd.name) catch unreachable;
        delta.title = title.value;
        delta.message = msg.value;
        delta.attach = .{ .issue = 0 };
        delta.commit() catch unreachable;

        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, delta.index });
        return ctx.response.redirect(loc, true) catch unreachable;
    }

    const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issue/new", .{rd.name});
    return ctx.response.redirect(loc, true) catch unreachable;
}

fn newComment(ctx: *Context) Error!void {
    const rd = Repos.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    if (ctx.reqdata.post) |post| {
        var valid = post.validator();
        const delta_id = try valid.require("did");
        const msg = try valid.require("comment");
        const issue_index = isHex(delta_id.value) orelse return error.Unrouteable;

        var delta = Delta.open(
            ctx.alloc,
            rd.name,
            issue_index,
        ) catch unreachable orelse return error.Unrouteable;
        _ = delta.loadThread(ctx.alloc) catch unreachable;
        const username = if (ctx.auth.valid())
            (ctx.auth.user(ctx.alloc) catch unreachable).username
        else
            "public";
        const c = Comment.new(username, msg.value) catch unreachable;

        delta.addComment(ctx.alloc, c) catch {};
        delta.commit() catch unreachable;
        var buf: [2048]u8 = undefined;
        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, issue_index });
        ctx.response.redirect(loc, true) catch unreachable;
        return;
    }
    return error.Unknown;
}

fn view(ctx: *Context) Error!void {
    const rd = Repos.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    const delta_id = ctx.uri.next().?;
    const index = isHex(delta_id) orelse return error.Unrouteable;

    var tmpl = Template.find("delta-issue.html");

    var delta = (Delta.open(ctx.alloc, rd.name, index) catch return error.Unrouteable) orelse return error.Unrouteable;
    try ctx.putContext("Repo", .{ .slice = rd.name });
    //dom.push(HTML.text(delta.repo));

    try ctx.putContext(
        "Title",
        .{ .slice = Bleach.sanitizeAlloc(ctx.alloc, delta.title, .{}) catch unreachable },
    );

    try ctx.putContext(
        "Desc",
        .{ .slice = Bleach.sanitizeAlloc(ctx.alloc, delta.message, .{}) catch unreachable },
    );

    _ = delta.loadThread(ctx.alloc) catch unreachable;
    if (delta.getComments(ctx.alloc)) |cm| {
        const comments: []Template.Context = try ctx.alloc.alloc(Template.Context, cm.len);

        for (cm, comments) |comment, *cctx| {
            cctx.* = Template.Context.init(ctx.alloc);
            const builder = comment.builder();
            builder.build(ctx.alloc, cctx) catch unreachable;
            try cctx.put(
                "Date",
                .{ .slice = try std.fmt.allocPrint(ctx.alloc, "{}", .{Humanize.unix(comment.updated)}) },
            );
        }
        try ctx.putContext("Comments", .{ .block = comments });
    } else |err| {
        std.debug.print("Unable to load comments for thread {} {}\n", .{ index, err });
        @panic("oops");
    }

    try ctx.putContext("Delta_id", .{ .slice = delta_id });

    try ctx.sendTemplate(&tmpl);
}

const DeltaListHtml = Template.PageData("delta-list.html");

fn list(ctx: *Context) Error!void {
    const rd = Repos.RouteData.make(&ctx.uri) orelse return error.Unrouteable;

    const last = Delta.last(rd.name) + 1;
    const ts = std.time.timestamp() - 86400;

    var d_list = std.ArrayList(S.DeltaList).init(ctx.alloc);
    for (0..last) |i| {
        // TODO implement seen
        var new_comments = false;
        var d = Delta.open(ctx.alloc, rd.name, i) catch continue orelse continue;
        if (!std.mem.eql(u8, d.repo, rd.name) or d.attach != .issue) {
            d.raze(ctx.alloc);
            continue;
        }

        _ = d.loadThread(ctx.alloc) catch unreachable;
        var cmtslen: usize = 0;
        if (d.getComments(ctx.alloc)) |cmts| {
            cmtslen = cmts.len;
            for (cmts) |c| {
                if (c.updated > ts) new_comments = true;
            }
        } else |_| {}

        try d_list.append(.{
            .index = try allocPrint(ctx.alloc, "0x{x}", .{d.index}),
            .title_uri = try allocPrint(
                ctx.alloc,
                "/repo/{s}/{s}/{x}",
                .{ d.repo, if (d.attach == .issue) "issues" else "diffs", d.index },
            ),
            .title = try Bleach.sanitizeAlloc(ctx.alloc, d.title, .{}),
            .comments_icon = try allocPrint(
                ctx.alloc,
                "<span><span class=\"icon{s}\">\xee\xa0\x9c</span> {}</span>",
                .{ if (new_comments) " new" else "", cmtslen },
            ),
        });
    }

    var default_search_buf: [0xFF]u8 = undefined;
    const def_search = try bufPrint(&default_search_buf, "is:issue repo:{s} ", .{rd.name});

    const meta_head = Template.Structs.MetaHeadHtml{
        .open_graph = .{},
    };

    var page = DeltaListHtml.init(.{
        .meta_head = meta_head,
        .body_header = .{ .nav = .{
            .nav_buttons = &try Repos.navButtons(ctx),
            .nav_auth = undefined,
        } },
        .delta_list = try d_list.toOwnedSlice(),
        .search = def_search,
    });

    try ctx.sendPage(&page);
}
