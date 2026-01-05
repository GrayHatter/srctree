const DeltaListHtml = T.PageData("delta-list.html");
const DeltaList = S.DeltaListHtml.DeltaList;
const DeltaMeta = S.DeltaListHtml.DeltaList.DeltaMeta;

pub fn deltaList(d: Delta, uri: []const u8, comments: CommentsMeta, meta: ?DeltaMeta, a: Allocator) !S.DeltaListHtml.DeltaList {
    const msg = if (d.message.len == 0) "&nbsp;" else d.message[0..@min(
        d.message.len,
        findPos(u8, d.message, 256, " ") orelse d.message.len,
        find(u8, d.message, "```") orelse d.message.len,
    )];

    // TODO implement seen
    return .{
        .index = try allocPrint(a, "{x}", .{d.index}),
        .uri_base = uri,
        .title = try allocPrint(a, "{f}", .{
            abx.Html{ .text = if (d.title.len == 0) "[No Title]" else d.title },
        }),
        .comment_new = if (comments.new) " new" else "",
        .comment_count = comments.count,
        .desc = try allocPrint(a, "{f}", .{abx.Html{ .text = msg }}),
        .delta_meta = meta,
    };
}

pub fn list(f: *Frame, itr: *Delta.RepoSearchIterator, uribase: []const u8, search_str: []const u8) RouterError!void {
    var d_list: ArrayList(DeltaList) = .{};
    while (itr.next(f.alloc, f.io)) |deltaC| {
        var d = deltaC;
        if (d.state.closed) continue;

        _ = d.loadThread(f.alloc, f.io) catch return error.ServerFault;
        const cmtsmeta = d.countComments(f.io);
        try d_list.append(f.alloc, try deltaList(d, uribase, cmtsmeta, null, f.alloc));
    }

    var og_title_b: [256]u8 = undefined;
    const meta_head = S.MetaHeadHtml{ .open_graph = .{
        .title = bufPrint(&og_title_b, "{} open issues", .{d_list.items.len}) catch unreachable,
    } };
    var body_header: S.BodyHeaderHtml = .{ .nav = .{ .nav_buttons = &try Repos.navButtons(f) } };
    if (f.user) |usr| {
        body_header.nav.nav_auth = usr.username.?;
    }

    var page = DeltaListHtml.init(.{
        .meta_head = meta_head,
        .body_header = body_header,
        //.search_action = uri_base,
        .delta_list = try d_list.toOwnedSlice(f.alloc),
        .search = search_str,
    });

    try f.sendPage(&page);
}

const Repos = @import("repos.zig");
const Types = @import("../types.zig");
const Delta = Types.Delta;
const CommentsMeta = Delta.CommentsMeta;

const verse = @import("verse");
const abx = verse.abx;
const Frame = verse.Frame;
const RouterError = verse.Router.Error;
const T = verse.template;
const S = T.Structs;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const findPos = std.mem.findPos;
const find = std.mem.find;
