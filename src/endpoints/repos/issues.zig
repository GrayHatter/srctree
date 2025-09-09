pub const verse_name = .issues;

pub const verse_aliases = .{
    .issue,
};

pub const routes = [_]Router.Match{
    ROUTE("", list),
    GET("new", new),
    POST("new", newPost),
    POST("add-comment", addComment),
};

pub const verse_router: Router.RouteFn = router;

pub const index = list;

fn isHex(input: []const u8) ?usize {
    for (input) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return std.fmt.parseInt(usize, input, 16) catch null;
}

pub fn router(ctx: *verse.Frame) Router.RoutingError!Router.BuildFn {
    std.debug.assert(std.mem.eql(u8, "issues", ctx.uri.next().?));
    const verb = ctx.uri.peek() orelse return Router.defaultRouter(ctx, &routes);

    if (isHex(verb)) |_| {
        return view;
    }

    return Router.defaultRouter(ctx, &routes);
}

const IssueNewPage = template.PageData("issue-new.html");

fn new(ctx: *verse.Frame) Error!void {
    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };

    var body_header: S.BodyHeaderHtml = .{ .nav = .{ .nav_buttons = &try Repos.navButtons(ctx) } };
    if (ctx.user) |usr| {
        body_header.nav.nav_auth = usr.username.?;
    }
    var page = IssueNewPage.init(.{
        .meta_head = meta_head,
        .body_header = body_header,
    });
    try ctx.sendPage(&page);
}

const IssueCreateReq = struct {
    title: []const u8,
    desc: []const u8,
};

fn newPost(ctx: *verse.Frame) Error!void {
    const rd = RouteData.init(ctx.uri) orelse return error.Unrouteable;
    var buf: [2048]u8 = undefined;
    if (ctx.request.data.post) |post| {
        const valid = post.validate(IssueCreateReq) catch return error.DataInvalid;
        var delta = Delta.new(
            rd.name,
            valid.title,
            valid.desc,
            if (ctx.user) |usr| usr.username.? else try allocPrint(ctx.alloc, "remote_address", .{}),
        ) catch unreachable;

        delta.attach = .issue;
        delta.commit() catch unreachable;

        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, delta.index });
        return ctx.redirect(loc, .see_other) catch unreachable;
    }

    const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issue/new", .{rd.name});
    return ctx.redirect(loc, .see_other) catch unreachable;
}

const AddCommentReq = struct {
    comment: []const u8,
    did: []const u8,
};

fn addComment(ctx: *verse.Frame) Error!void {
    const rd = RouteData.init(ctx.uri) orelse return error.Unrouteable;
    const post = ctx.request.data.post orelse return error.DataMissing;
    const validate = post.validate(AddCommentReq) catch return error.DataInvalid;

    const did: usize = std.fmt.parseInt(usize, validate.did, 16) catch return error.DataInvalid;

    var delta = Delta.open(ctx.alloc, rd.name, did) catch
        return error.Unknown;
    const username = if (ctx.user) |usr| usr.username.? else "public";

    delta.addComment(ctx.alloc, .{ .author = username, .message = validate.comment }) catch {};
    var buf: [2048]u8 = undefined;
    const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, did });
    ctx.redirect(loc, .see_other) catch unreachable;
    return;
}

const DeltaIssuePage = template.PageData("delta-issue.html");

fn view(ctx: *verse.Frame) Error!void {
    const rd = RouteData.init(ctx.uri) orelse return error.Unrouteable;
    const delta_id = ctx.uri.next().?;
    const idx = isHex(delta_id) orelse return error.Unrouteable;

    var delta = Delta.open(ctx.alloc, rd.name, idx) catch return error.Unrouteable;

    var root_thread: []S.Thread = &[0]S.Thread{};
    if (delta.loadThread(ctx.alloc)) |thread| {
        root_thread = try ctx.alloc.alloc(S.Thread, thread.messages.items.len);
        for (thread.messages.items, root_thread) |msg, *c_ctx| {
            switch (msg.kind) {
                .comment => {
                    c_ctx.* = .{
                        .author = try verse.abx.Html.cleanAlloc(ctx.alloc, msg.author.?),
                        .date = try allocPrint(ctx.alloc, "{f}", .{Humanize.unix(msg.updated)}),
                        .message = try verse.abx.Html.cleanAlloc(ctx.alloc, msg.message.?),
                        .direct_reply = .{
                            .uri = try allocPrint(ctx.alloc, "{}/direct_reply/{x}", .{ idx, msg.hash[0..] }),
                        },
                        .sub_thread = null,
                    };
                },
                //else => {
                //    c_ctx.* = .{
                //        .author = "",
                //        .date = "",
                //        .message = "unsupported message type",
                //        .direct_reply = null,
                //        .sub_thread = null,
                //    };
                //},
            }
        }
    } else |err| {
        std.debug.print("Unable to load comments for thread {} {}\n", .{ idx, err });
        @panic("oops");
    }

    const description = Highlight.Markdown.translate(ctx.alloc, delta.message) catch
        try abx.Html.cleanAlloc(ctx.alloc, delta.message);

    const username = if (ctx.user) |usr| usr.username.? else "anon";
    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };

    var body_header: S.BodyHeaderHtml = .{ .nav = .{ .nav_buttons = &try Repos.navButtons(ctx) } };
    if (ctx.user) |usr| {
        body_header.nav.nav_auth = usr.username.?;
    }

    const status: []const u8 = if (delta.closed)
        "<span class=closed>closed</span>"
    else
        "<span class=open>open</span>";

    var page = DeltaIssuePage.init(.{
        .meta_head = meta_head,
        .body_header = body_header,
        .title = verse.abx.Html.cleanAlloc(ctx.alloc, delta.title) catch unreachable,
        .description = description,
        .delta_id = delta_id,
        .current_username = username,
        .creator = if (delta.author) |author| try abx.Html.cleanAlloc(ctx.alloc, author) else null,
        .status = status,
        .created = try allocPrint(ctx.alloc, "{f}", .{Humanize.unix(delta.created)}),
        .updated = try allocPrint(ctx.alloc, "{f}", .{Humanize.unix(delta.updated)}),
        .comments = .{
            .thread = root_thread,
        },
    });
    // required because linux will validate data.[slice].ptr and zig likes to
    // pretend that setting .ptr = undefined when .len == 0
    if (page.data.title.len == 0) {
        page.data.title = "[No Title]";
    }

    if (page.data.description.len == 0) {
        page.data.description = "<span class=\"muted\">No description provided</span>";
    }

    try ctx.sendPage(&page);
}

const DeltaListHtml = template.PageData("delta-list.html");

fn list(ctx: *verse.Frame) Error!void {
    const rd = RouteData.init(ctx.uri) orelse return error.Unrouteable;

    const last = (Types.currentIndexNamed(.deltas, rd.name) catch 0) + 1;
    var d_list: ArrayList(S.DeltaList) = .{};
    for (0..last) |i| {

        // TODO implement seen
        var d = Delta.open(ctx.alloc, rd.name, i) catch continue;
        if (!std.mem.eql(u8, d.repo, rd.name) or d.attach != .issue) {
            d.raze(ctx.alloc);
            continue;
        }

        _ = d.loadThread(ctx.alloc) catch return error.Unknown;
        const cmtsmeta = d.countComments();

        try d_list.append(ctx.alloc, .{
            .index = try allocPrint(ctx.alloc, "0x{x}", .{d.index}),
            .title_uri = try allocPrint(
                ctx.alloc,
                "/repo/{s}/{s}/{x}",
                .{ d.repo, if (d.attach == .issue) "issues" else "diffs", d.index },
            ),
            .title = try verse.abx.Html.cleanAlloc(ctx.alloc, d.title),
            .comment_new = if (cmtsmeta.new) " new" else "",
            .comment_count = cmtsmeta.count,
            .desc = try verse.abx.Html.cleanAlloc(ctx.alloc, d.message),
        });
    }

    var default_search_buf: [0xFF]u8 = undefined;
    const def_search = try bufPrint(&default_search_buf, "is:issue repo:{s} ", .{rd.name});

    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };
    var body_header: S.BodyHeaderHtml = .{ .nav = .{ .nav_buttons = &try Repos.navButtons(ctx) } };
    if (ctx.user) |usr| {
        body_header.nav.nav_auth = usr.username.?;
    }

    var page = DeltaListHtml.init(.{
        .meta_head = meta_head,
        .body_header = body_header,
        .delta_list = try d_list.toOwnedSlice(ctx.alloc),
        .search = def_search,
    });

    try ctx.sendPage(&page);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;

const verse = @import("verse");
const abx = verse.abx;
const Router = verse.Router;
const template = verse.template;
const Error = Router.Error;
const ROUTE = Router.ROUTE;
const POST = Router.POST;
const GET = Router.GET;
const S = template.Structs;

const Repos = @import("../repos.zig");
const RouteData = Repos.RouteData;

const Types = @import("../../types.zig");
const Delta = Types.Delta;
const Humanize = @import("../../humanize.zig");
const Highlight = @import("../../syntax-highlight.zig");
