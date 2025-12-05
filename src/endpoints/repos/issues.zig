pub const verse_name = .issues;

pub const verse_aliases = .{
    .issue,
};

pub const verse_router: Router.RouteFn = router;

pub const routes = [_]Router.Match{
    ROUTE("", list),
    GET("new", new),
    POST("new", newPost),
    POST("add-comment", addComment),
};

pub const index = list;

fn isHex(input: []const u8) ?usize {
    for (input) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return std.fmt.parseInt(usize, input, 16) catch null;
}

pub fn router(ctx: *verse.Frame) Router.RoutingError!Router.BuildFn {
    const current = ctx.uri.next() orelse return error.Unrouteable;
    if (!eql(u8, "issues", current) and !eql(u8, "issue", current)) return error.Unrouteable;
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

fn newPost(f: *verse.Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    var buf: [2048]u8 = undefined;
    if (f.request.data.post) |post| {
        const valid = post.validate(IssueCreateReq) catch return error.DataInvalid;
        var delta = Delta.new(
            rd.name,
            valid.title,
            valid.desc,
            if (f.user) |usr| usr.username.? else try allocPrint(f.alloc, "remote_address", .{}),
            f.io,
        ) catch unreachable;

        delta.attach = .issue;
        delta.commit(f.io) catch unreachable;

        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, delta.index });
        return f.redirect(loc, .see_other) catch unreachable;
    }

    const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issue/new", .{rd.name});
    return f.redirect(loc, .see_other) catch unreachable;
}

const AddCommentReq = struct {
    comment: []const u8,
    did: []const u8,
};

fn addComment(f: *verse.Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    const post = f.request.data.post orelse return error.DataMissing;
    const validate = post.validate(AddCommentReq) catch return error.DataInvalid;

    const did: usize = std.fmt.parseInt(usize, validate.did, 16) catch return error.DataInvalid;

    var delta = Delta.open(rd.name, did, f.alloc, f.io) catch
        return error.Unknown;
    const username = if (f.user) |usr| usr.username.? else "public";

    delta.addComment(.{ .author = username, .message = validate.comment }, f.alloc, f.io) catch {};
    var buf: [2048]u8 = undefined;
    const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, did });
    f.redirect(loc, .see_other) catch unreachable;
    return;
}

const DeltaIssuePage = template.PageData("delta-issue.html");

fn view(f: *verse.Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    const delta_id = f.uri.next().?;
    const idx = isHex(delta_id) orelse return error.Unrouteable;

    var delta = Delta.open(rd.name, idx, f.alloc, f.io) catch return error.Unrouteable;

    var root_thread: []S.CommentThreadHtml.Thread = &[0]S.CommentThreadHtml.Thread{};
    const now = (Io.Clock.now(.real, f.io) catch unreachable).toSeconds();
    if (delta.loadThread(f.alloc, f.io)) |thread| {
        root_thread = try f.alloc.alloc(S.CommentThreadHtml.Thread, thread.messages.items.len);
        for (thread.messages.items, root_thread) |msg, *c_ctx| {
            switch (msg.kind) {
                .comment => {
                    c_ctx.* = .{
                        .author = try allocPrint(f.alloc, "{f}", .{verse.abx.Html{ .text = msg.author.? }}),
                        .date = try allocPrint(f.alloc, "{f}", .{Humanize.unix(msg.updated, now)}),
                        .message = try allocPrint(f.alloc, "{f}", .{verse.abx.Html{ .text = msg.message.? }}),
                        .direct_reply = .{
                            .uri = try allocPrint(f.alloc, "{}/direct_reply/{x}", .{ idx, msg.hash[0..] }),
                        },
                        .sub_thread = null,
                    };
                },
                .diff_update => {
                    // TODO Is this unreachable?
                    c_ctx.* = .{
                        .author = try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = msg.author.? }}),
                        .date = try allocPrint(f.alloc, "{f}", .{Humanize.unix(msg.updated, now)}),
                        .message = msg.message.?,
                        .direct_reply = null,
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

    const description = Highlight.Markdown.translate(f.alloc, delta.message) catch
        try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = delta.message }});

    const username = if (f.user) |usr| usr.username.? else "anon";
    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };

    var body_header: S.BodyHeaderHtml = .{ .nav = .{ .nav_buttons = &try Repos.navButtons(f) } };
    if (f.user) |usr| {
        body_header.nav.nav_auth = usr.username.?;
    }

    const status: []const u8 = if (delta.state.closed)
        "<span class=closed>closed</span>"
    else
        "<span class=open>open</span>";

    var page = DeltaIssuePage.init(.{
        .meta_head = meta_head,
        .body_header = body_header,
        .title = allocPrint(f.alloc, "{f}", .{verse.abx.Html{ .text = delta.title }}) catch unreachable,
        .description = description,
        .delta_id = delta_id,
        .current_username = username,
        .creator = if (delta.author) |author| try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = author }}) else null,
        .status = status,
        .created = try allocPrint(f.alloc, "{f}", .{Humanize.unix(delta.created, now)}),
        .updated = try allocPrint(f.alloc, "{f}", .{Humanize.unix(delta.updated, now)}),
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

    try f.sendPage(&page);
}

const DeltaListHtml = template.PageData("delta-list.html");

fn list(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;

    const uri_base = try allocPrint(f.alloc, "/repo/{s}/issue", .{rd.name});
    const last = (Types.currentIndexNamed(.deltas, rd.name, f.io) catch 0) + 1;
    var d_list: ArrayList(S.DeltaListHtml.DeltaList) = .{};
    for (0..last) |i| {

        // TODO implement seen
        var d = Delta.open(rd.name, i, f.alloc, f.io) catch continue;
        if (!std.mem.eql(u8, d.repo, rd.name) or d.attach != .issue) {
            d.raze(f.alloc);
            continue;
        }

        _ = d.loadThread(f.alloc, f.io) catch return error.Unknown;
        const cmtsmeta = d.countComments(f.io);

        try d_list.append(f.alloc, .{
            .index = try allocPrint(f.alloc, "{x}", .{d.index}),
            .uri_base = uri_base,
            .title = try allocPrint(f.alloc, "{f}", .{verse.abx.Html{ .text = d.title }}),
            .comment_new = if (cmtsmeta.new) " new" else "",
            .comment_count = cmtsmeta.count,
            .desc = try allocPrint(f.alloc, "{f}", .{verse.abx.Html{ .text = d.message }}),
            .delta_meta = null,
        });
    }

    var default_search_buf: [0xFF]u8 = undefined;
    const def_search = try bufPrint(&default_search_buf, "repo:{s} is:issue", .{rd.name});

    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };
    var body_header: S.BodyHeaderHtml = .{ .nav = .{ .nav_buttons = &try Repos.navButtons(f) } };
    if (f.user) |usr| {
        body_header.nav.nav_auth = usr.username.?;
    }

    var page = DeltaListHtml.init(.{
        .meta_head = meta_head,
        .body_header = body_header,
        //.search_action = uri_base,
        .delta_list = try d_list.toOwnedSlice(f.alloc),
        .search = def_search,
    });

    try f.sendPage(&page);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const eql = std.mem.eql;

const verse = @import("verse");
const Frame = verse.Frame;
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
