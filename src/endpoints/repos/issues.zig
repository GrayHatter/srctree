const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const fmtSliceHexLower = std.fmt.fmtSliceHexLower;

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

const IssueNewPage = Template.PageData("issue-new.html");

fn new(ctx: *Context) Error!void {
    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };
    var page = IssueNewPage.init(.{
        .meta_head = meta_head,
        .body_header = .{ .nav = .{
            .nav_buttons = &try Repos.navButtons(ctx),
            .nav_auth = undefined,
        } },
    });
    try ctx.sendPage(&page);
}

const IssueCreate = struct {
    title: []const u8,
    desc: []const u8,
};

fn newPost(ctx: *Context) Error!void {
    const rd = Repos.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    var buf: [2048]u8 = undefined;
    if (ctx.reqdata.post) |post| {
        const valid = post.validate(IssueCreate) catch return error.BadData;
        var delta = Delta.new(
            rd.name,
            valid.title,
            valid.desc,
            if (ctx.auth.valid())
                (ctx.auth.user(ctx.alloc) catch unreachable).username
            else
                try allocPrint(ctx.alloc, "remote_address", .{}),
        ) catch unreachable;

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

const DeltaIssuePage = Template.PageData("delta-issue.html");

fn view(ctx: *Context) Error!void {
    const rd = Repos.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    const delta_id = ctx.uri.next().?;
    const index = isHex(delta_id) orelse return error.Unrouteable;

    var delta = (Delta.open(ctx.alloc, rd.name, index) catch return error.Unrouteable) orelse return error.Unrouteable;

    _ = delta.loadThread(ctx.alloc) catch unreachable;
    var root_thread: []S.Thread = &[0]S.Thread{};
    if (delta.getMessages(ctx.alloc)) |messages| {
        root_thread = try ctx.alloc.alloc(S.Thread, messages.len);
        for (messages, root_thread) |msg, *c_ctx| {
            switch (msg) {
                .comment => |comment| {
                    c_ctx.* = .{
                        .author = try Bleach.sanitizeAlloc(ctx.alloc, comment.author, .{}),
                        .date = try allocPrint(ctx.alloc, "{}", .{Humanize.unix(comment.updated)}),
                        .message = try Bleach.sanitizeAlloc(ctx.alloc, comment.message, .{}),
                        .direct_reply = .{ .uri = try allocPrint(ctx.alloc, "{}/direct_reply/{x}", .{ index, fmtSliceHexLower(comment.hash[0..]) }) },
                        .sub_thread = null,
                    };
                },
                else => {
                    c_ctx.* = .{ .author = "", .date = "", .message = "unsupported message type", .direct_reply = null, .sub_thread = null };
                },
            }
        }
    } else |err| {
        std.debug.print("Unable to load comments for thread {} {}\n", .{ index, err });
        @panic("oops");
    }

    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };
    var page = DeltaIssuePage.init(.{
        .meta_head = meta_head,
        .body_header = .{ .nav = .{
            .nav_buttons = &try Repos.navButtons(ctx),
            .nav_auth = undefined,
        } },
        .title = Bleach.sanitizeAlloc(ctx.alloc, delta.title, .{}) catch unreachable,
        .desc = Bleach.sanitizeAlloc(ctx.alloc, delta.message, .{}) catch unreachable,
        .delta_id = delta_id,
        .comments = .{
            .thread = root_thread,
        },
    });

    try ctx.sendPage(&page);
}

const DeltaListHtml = Template.PageData("delta-list.html");

fn list(ctx: *Context) Error!void {
    const rd = Repos.RouteData.make(&ctx.uri) orelse return error.Unrouteable;

    const last = Delta.last(rd.name) + 1;

    var d_list = std.ArrayList(S.DeltaList).init(ctx.alloc);
    for (0..last) |i| {
        // TODO implement seen
        var d = Delta.open(ctx.alloc, rd.name, i) catch continue orelse continue;
        if (!std.mem.eql(u8, d.repo, rd.name) or d.attach != .issue) {
            d.raze(ctx.alloc);
            continue;
        }

        _ = d.loadThread(ctx.alloc) catch unreachable;
        const cmtsmeta = d.countComments();

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
                .{ if (cmtsmeta.new) " new" else "", cmtsmeta.count },
            ),
            .desc = try Bleach.sanitizeAlloc(ctx.alloc, d.message, .{}),
        });
    }

    var default_search_buf: [0xFF]u8 = undefined;
    const def_search = try bufPrint(&default_search_buf, "is:issue repo:{s} ", .{rd.name});

    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };

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
