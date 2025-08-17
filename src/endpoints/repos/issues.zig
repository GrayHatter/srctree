pub const verse_name = .issues;

pub const verse_aliases = .{
    .issue,
};

pub const routes = [_]Router.Match{
    ROUTE("", list),
    GET("new", new),
    POST("new", newPost),
    POST("add-comment", newComment),
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
    var page = IssueNewPage.init(.{
        .meta_head = meta_head,
        .body_header = .{ .nav = .{
            .nav_buttons = &try Repos.navButtons(ctx),
        } },
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

fn newComment(ctx: *verse.Frame) Error!void {
    const rd = RouteData.init(ctx.uri) orelse return error.Unrouteable;
    if (ctx.request.data.post) |post| {
        var valid = post.validator();
        const delta_id = try valid.require("did");
        const msg = try valid.require("comment");
        const issue_index = isHex(delta_id.value) orelse return error.Unrouteable;

        var delta = Delta.open(ctx.alloc, rd.name, issue_index) catch
            return error.Unknown;
        const username = if (ctx.user) |usr| usr.username.? else "public";

        var thread = delta.loadThread(ctx.alloc) catch return error.Unknown;
        thread.newComment(ctx.alloc, username, msg.value) catch {};
        delta.commit() catch unreachable;
        var buf: [2048]u8 = undefined;
        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, issue_index });
        ctx.redirect(loc, .see_other) catch unreachable;
        return;
    }
    return error.Unknown;
}

const DeltaIssuePage = template.PageData("delta-issue.html");

fn view(ctx: *verse.Frame) Error!void {
    const rd = RouteData.init(ctx.uri) orelse return error.Unrouteable;
    const delta_id = ctx.uri.next().?;
    const idx = isHex(delta_id) orelse return error.Unrouteable;

    var delta = Delta.open(ctx.alloc, rd.name, idx) catch return error.Unrouteable;

    _ = delta.loadThread(ctx.alloc) catch unreachable;
    var root_thread: []S.Thread = &[0]S.Thread{};
    if (delta.getMessages(ctx.alloc)) |messages| {
        root_thread = try ctx.alloc.alloc(S.Thread, messages.len);
        for (messages, root_thread) |msg, *c_ctx| {
            switch (msg.kind) {
                .comment => {
                    c_ctx.* = .{
                        .author = try verse.abx.Html.cleanAlloc(ctx.alloc, msg.author.?),
                        .date = try allocPrint(ctx.alloc, "{}", .{Humanize.unix(msg.updated)}),
                        .message = try verse.abx.Html.cleanAlloc(ctx.alloc, msg.message.?),
                        .direct_reply = .{ .uri = try allocPrint(ctx.alloc, "{}/direct_reply/{x}", .{
                            idx,
                            fmtSliceHexLower(msg.hash[0..]),
                        }) },
                        .sub_thread = null,
                    };
                },
                //else => {
                //    c_ctx.* = .{ .author = "", .date = "", .message = "unsupported message type", .direct_reply = null, .sub_thread = null };
                //},
            }
        }
    } else |err| {
        std.debug.print("Unable to load comments for thread {} {}\n", .{ idx, err });
        @panic("oops");
    }

    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };
    var page = DeltaIssuePage.init(.{
        .meta_head = meta_head,
        .body_header = .{ .nav = .{
            .nav_buttons = &try Repos.navButtons(ctx),
        } },
        .title = verse.abx.Html.cleanAlloc(ctx.alloc, delta.title) catch unreachable,
        .desc = verse.abx.Html.cleanAlloc(ctx.alloc, delta.message) catch unreachable,
        .delta_id = delta_id,
        .comments = .{
            .thread = root_thread,
        },
    });

    try ctx.sendPage(&page);
}

const DeltaListHtml = template.PageData("delta-list.html");

fn list(ctx: *verse.Frame) Error!void {
    const rd = RouteData.init(ctx.uri) orelse return error.Unrouteable;

    const last = (Types.currentIndex(.deltas) catch 0) + 1;
    std.debug.print("last {}\n", .{last});

    var d_list = std.ArrayList(S.DeltaList).init(ctx.alloc);
    for (0..last) |i| {
        // TODO implement seen
        var d = Delta.open(ctx.alloc, rd.name, i) catch continue;
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
            .title = try verse.abx.Html.cleanAlloc(ctx.alloc, d.title),
            .comments_icon = try allocPrint(
                ctx.alloc,
                "<span><span class=\"icon{s}\">\xee\xa0\x9c</span> {}</span>",
                .{ if (cmtsmeta.new) " new" else "", cmtsmeta.count },
            ),
            .desc = try verse.abx.Html.cleanAlloc(ctx.alloc, d.message),
        });
    }

    var default_search_buf: [0xFF]u8 = undefined;
    const def_search = try bufPrint(&default_search_buf, "is:issue repo:{s} ", .{rd.name});

    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };

    var page = DeltaListHtml.init(.{
        .meta_head = meta_head,
        .body_header = .{ .nav = .{
            .nav_buttons = &try Repos.navButtons(ctx),
        } },
        .delta_list = try d_list.toOwnedSlice(),
        .search = def_search,
    });

    try ctx.sendPage(&page);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const fmtSliceHexLower = std.fmt.fmtSliceHexLower;

const verse = @import("verse");
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
