const std = @import("std");

const Allocator = std.mem.Allocator;

const DOM = @import("../../dom.zig");
const HTML = @import("../../html.zig");
const Context = @import("../../context.zig");
const Response = @import("../../response.zig");
const Template = @import("../../template.zig");
const Route = @import("../../routes.zig");
const Error = Route.Error;
const UriIter = Route.UriIter;
const ROUTE = Route.ROUTE;
const POST = Route.POST;
const GET = Route.GET;

const UserData = @import("../../request_data.zig").UserData;

const Repo = @import("../repos.zig");
const Commits = @import("commits.zig");

const Types = @import("../../types.zig");
const Thread = Types.Thread;
const Delta = Types.Delta;
const Comment = Types.Comment;

const Patch = @import("../../patch.zig");
const Humanize = @import("../../humanize.zig");
const CURL = @import("../../curl.zig");
const Bleach = @import("../../bleach.zig");

pub const routes = [_]Route.Match{
    ROUTE("", list),
    GET("new", new),
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
    std.debug.assert(std.mem.eql(u8, "diffs", ctx.uri.next().?));
    const verb = ctx.uri.peek() orelse return Route.router(ctx, &routes);

    if (isHex(verb)) |_| {
        return view;
    }

    return Route.router(ctx, &routes);
}

fn new(ctx: *Context) Error!void {
    var tmpl = comptime Template.find("diff-new.html");
    try ctx.sendTemplate(&tmpl);
}

fn inNetwork(str: []const u8) bool {
    if (!std.mem.startsWith(u8, str, "https://srctree.gr.ht")) return false;
    for (str) |c| if (c == '@') return false;
    return true;
}

const IssueCreateReq = struct {
    patch_uri: []const u8,
    title: []const u8,
    desc: []const u8,
    //action: ?union(enum) {
    //    submit: bool,
    //    preview: bool,
    //},

};

fn newPost(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    if (ctx.req_data.post_data) |post| {
        const udata = UserData(IssueCreateReq).init(post) catch return error.BadData;

        var delta = Delta.new(rd.name) catch unreachable;
        //delta.src = src;
        delta.title = udata.title;
        delta.message = udata.desc;
        delta.attach = .{ .diff = 0 };
        delta.commit() catch unreachable;

        if (inNetwork(udata.patch_uri)) {
            std.debug.print("src {s}\ntitle {s}\ndesc {s}\naction {s}\n", .{
                udata.patch_uri,
                udata.title,
                udata.desc,
                "unimplemented",
            });
            const data = Patch.loadRemote(ctx.alloc, udata.patch_uri) catch unreachable;
            const filename = std.fmt.allocPrint(
                ctx.alloc,
                "data/patch/{s}.{x}.patch",
                .{ rd.name, delta.index },
            ) catch unreachable;
            var file = std.fs.cwd().createFile(filename, .{}) catch unreachable;
            defer file.close();
            file.writer().writeAll(data.blob) catch unreachable;
        }
        var buf: [2048]u8 = undefined;
        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/diffs/{x}", .{ rd.name, delta.index });
        return ctx.response.redirect(loc, true) catch unreachable;
    }

    var tmpl = Template.find("diff-new.html");
    try ctx.sendTemplate(&tmpl);
}

fn newComment(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    var buf: [2048]u8 = undefined;
    if (ctx.req_data.post_data) |post| {
        var valid = post.validator();
        const delta_id = try valid.require("did");
        const delta_index = isHex(delta_id.value) orelse return error.Unrouteable;
        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/diffs/{x}", .{ rd.name, delta_index });

        const msg = try valid.require("comment");
        if (msg.value.len < 2) return ctx.response.redirect(loc, true) catch unreachable;

        var delta = Delta.open(ctx.alloc, rd.name, delta_index) catch unreachable orelse return error.Unrouteable;
        const username = if (ctx.auth.valid())
            (ctx.auth.user(ctx.alloc) catch unreachable).username
        else
            "public";
        const c = Comment.new(username, msg.value) catch unreachable;
        _ = delta.loadThread(ctx.alloc) catch unreachable;
        delta.addComment(ctx.alloc, c) catch unreachable;
        delta.commit() catch unreachable;
        return ctx.response.redirect(loc, true) catch unreachable;
    }
    return error.Unknown;
}

fn view(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    const delta_id = ctx.uri.next().?;
    const index = isHex(delta_id) orelse return error.Unrouteable;

    var tmpl = Template.find("delta-diff.html");

    var dom = DOM.new(ctx.alloc);

    var delta = Delta.open(ctx.alloc, rd.name, index) catch |err| switch (err) {
        error.InvalidTarget => return error.Unrouteable,
        error.InputOutput => unreachable,
        error.Other => unreachable,
        else => unreachable,
    } orelse return error.Unrouteable;

    dom = dom.open(HTML.element("context", null, null));
    dom.push(HTML.text(rd.name));
    dom = dom.open(HTML.p(null, null));
    dom.push(HTML.text(Bleach.sanitizeAlloc(ctx.alloc, delta.title, .{}) catch unreachable));
    dom = dom.close();
    dom = dom.open(HTML.p(null, null));
    dom.push(HTML.text(Bleach.sanitizeAlloc(ctx.alloc, delta.message, .{}) catch unreachable));
    dom = dom.close();
    dom = dom.close();

    _ = try ctx.addElements(ctx.alloc, "Patch_header", dom.done());

    // meme saved to protect history
    //for ([_]Comment{ .{
    //    .author = "grayhatter",
    //    .message = "Wow, srctree's Diff view looks really good!",
    //}, .{
    //    .author = "robinli",
    //    .message = "I know, it's clearly the best I've even seen. Soon it'll even look good in Hastur!",
    //} }) |cm| {
    //    comments.pushSlice(addComment(ctx.alloc, cm) catch unreachable);
    //}

    _ = delta.loadThread(ctx.alloc) catch unreachable;

    if (delta.getComments(ctx.alloc)) |comments| {
        const contexts: []Template.Context = try ctx.alloc.alloc(Template.Context, comments.len);
        for (comments, contexts) |*comment, *c_ctx| c_ctx.* = try comment.toContext(ctx.alloc);
        try ctx.putContext("Comments", .{ .block = contexts });
    } else |err| {
        std.debug.print("Unable to load comments for thread {} {}\n", .{ index, err });
        @panic("oops");
    }

    try ctx.putContext("Delta_id", .{ .slice = delta_id });

    const filename = try std.fmt.allocPrint(ctx.alloc, "data/patch/{s}.{x}.patch", .{ rd.name, delta.index });
    const file: ?std.fs.File = std.fs.cwd().openFile(filename, .{}) catch null;
    if (file) |f| {
        const fdata = f.readToEndAlloc(ctx.alloc, 0xFFFFF) catch return error.Unknown;
        var patch = Patch.Patch.init(fdata);
        const patch_html = try Commits.patchHtml(ctx.alloc, &patch);
        _ = try ctx.addElementsFmt(ctx.alloc, "{pretty}", "Patch", patch_html);
        f.close();
    } else try ctx.putContext("Patch", .{ .slice = "Patch not found" });

    try ctx.sendTemplate(&tmpl);
}

fn list(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;

    const last = Delta.last(rd.name) + 1;
    var end: usize = 0;

    var tmpl_ctx = try ctx.alloc.alloc(Template.Context, last);
    for (0..last) |i| {
        var d = Delta.open(ctx.alloc, rd.name, i) catch continue orelse continue;
        if (!std.mem.eql(u8, d.repo, rd.name) or d.attach != .diff) {
            d.raze(ctx.alloc);
            continue;
        }

        const delta_ctx = &tmpl_ctx[end];
        delta_ctx.* = Template.Context.init(ctx.alloc);
        const builder = d.builder();
        builder.build(ctx.alloc, delta_ctx) catch unreachable;
        _ = d.loadThread(ctx.alloc) catch unreachable;
        if (d.getComments(ctx.alloc)) |cmts| {
            try delta_ctx.putSlice(
                "Comments_icon",
                try std.fmt.allocPrint(ctx.alloc, "<span class=\"icon\">\xee\xa0\x9c {}</span>", .{cmts.len}),
            );
        } else |_| unreachable;
        end += 1;
        continue;
    }
    var tmpl = Template.find("deltalist.html");
    try ctx.putContext("List", .{ .block = tmpl_ctx[0..end] });
    try ctx.sendTemplate(&tmpl);
}
