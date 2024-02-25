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
const Comments = Endpoint.Types.Comments;
const Comment = Comments.Comment;
const Deltas = Endpoint.Types.Deltas;
const Humanize = @import("../../humanize.zig");

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
    ctx.sendTemplate(&tmpl) catch unreachable;
}

fn newPost(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    var buf: [2048]u8 = undefined;
    if (ctx.response.usr_data) |usrdata| if (usrdata.post_data) |post| {
        var valid = post.validator();
        const title = try valid.require("title");
        const msg = try valid.require("desc");
        var delta = Deltas.new(rd.name) catch unreachable;
        delta.title = title.value;
        delta.desc = msg.value;
        delta.attach = .{ .issue = 0 };
        delta.writeOut() catch unreachable;

        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, delta.index });
        return ctx.response.redirect(loc, true) catch unreachable;
    };

    const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issue/new", .{rd.name});
    return ctx.response.redirect(loc, true) catch unreachable;
}

fn newComment(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    if (ctx.response.usr_data) |usrdata| if (usrdata.post_data) |post| {
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
        var c = Comments.new("name", msg.value) catch unreachable;

        delta.addComment(ctx.alloc, c) catch {};
        delta.writeOut() catch unreachable;
        var buf: [2048]u8 = undefined;
        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, issue_index });
        ctx.response.redirect(loc, true) catch unreachable;
        return;
    };
    return error.Unknown;
}

fn view(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    const delta_id = ctx.uri.next().?;
    const index = isHex(delta_id) orelse return error.Unrouteable;

    var tmpl = Template.find("delta-issue.html");
    tmpl.init(ctx.alloc);

    var dom = DOM.new(ctx.alloc);

    var delta = (Deltas.open(ctx.alloc, rd.name, index) catch return error.Unrouteable) orelse return error.Unrouteable;
    dom.push(HTML.text(rd.name));
    dom.push(HTML.text(delta.repo));
    dom.push(HTML.text(Bleach.sanitizeAlloc(ctx.alloc, delta.title, .{}) catch unreachable));
    dom.push(HTML.text(Bleach.sanitizeAlloc(ctx.alloc, delta.desc, .{}) catch unreachable));
    _ = try tmpl.addElements(ctx.alloc, "issue", dom.done());

    _ = delta.loadThread(ctx.alloc) catch unreachable;
    if (delta.getComments(ctx.alloc)) |cm| {
        var comments: []Template.Context = try ctx.alloc.alloc(Template.Context, cm.len);

        for (cm, comments) |comment, *cctx| {
            cctx.* = Template.Context.init(ctx.alloc);
            const builder = comment.builder();
            try builder.build(cctx);
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

    ctx.sendTemplate(&tmpl) catch unreachable;
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
        try builder.build(delta_ctx);
        try delta_ctx.put("index", try std.fmt.allocPrint(ctx.alloc, "0x{x}", .{d.index}));
        try delta_ctx.put("title_uri", try std.fmt.allocPrint(ctx.alloc, "{x}", .{d.index}));
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
    ctx.sendTemplate(&tmpl) catch return error.Unknown;
}
