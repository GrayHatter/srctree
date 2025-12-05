pub const verse_name = .search;

pub const verse_aliases = .{
    .inbox,
};

pub const verse_routes = [_]Routes.Match{
    ROUTE("search", index),
    ROUTE("inbox", inbox),
};

const SearchReq = struct {
    q: ?[]const u8,
};

fn inbox(ctx: *Frame) Error!void {
    return custom(ctx, "owner:me");
}

pub fn index(ctx: *Frame) Error!void {
    const udata = ctx.request.data.query.validate(SearchReq) catch return error.DataInvalid;
    const query_str = udata.q orelse "";
    return custom(ctx, query_str);
}

const DeltaListPage = Template.PageData("delta-list.html");

fn custom(f: *Frame, search_str: []const u8) Error!void {
    var rules: ArrayList(Delta.SearchRule) = .{};

    var itr = splitScalar(u8, search_str, ' ');
    while (itr.next()) |r_line| {
        var line = r_line;
        line = std.mem.trim(u8, line, " ");
        if (line.len == 0) continue;
        try rules.append(f.alloc, .parse(line));
    }

    for (rules.items) |rule| {
        if (false)
            std.debug.print("rule = {s} : {s}\n", .{ rule.subject, rule.match });
    }

    var d_list: ArrayList(S.DeltaListHtml.DeltaList) = .{};
    var search_results = Delta.searchAny(rules.items, f.io);
    while (search_results.next(f.alloc, f.io)) |deltaC| {
        if (deltaC.title.len == 0) continue;
        var delt: Delta = deltaC;
        _ = delt.loadThread(f.alloc, f.io) catch return error.Unknown;
        const cmtsmeta = delt.countComments(f.io);
        const desc = if (delt.message.len == 0) "&nbsp;" else try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = delt.message }});
        try d_list.append(f.alloc, .{
            .index = try allocPrint(f.alloc, "{x}", .{delt.index}),
            .uri_base = try allocPrint(
                f.alloc,
                "/repo/{s}/{s}",
                .{ delt.repo, if (delt.attach == .issue) "issue" else "diff" },
            ),
            .title = try std.fmt.allocPrint(f.alloc, "{f}", .{abx.Html{ .text = delt.title }}),
            .comment_new = if (cmtsmeta.new) " new" else "",
            .comment_count = cmtsmeta.count,
            .desc = desc,
            .delta_meta = .{ .repo = delt.repo, .flavor = if (delt.attach == .issue) "issue" else "diff" },
        });
    }

    const btns = [1]Template.Structs.NavButtons{.{ .name = "inbox", .extra = 0, .url = "/inbox" }};

    var page = DeltaListPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .nav = .{ .nav_buttons = &btns } },
        .delta_list = d_list.items,
        .search = allocPrint(f.alloc, "{f}", .{abx.Html{ .text = search_str }}) catch unreachable,
    });

    try f.sendPage(&page);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const splitScalar = std.mem.splitScalar;
const allocPrint = std.fmt.allocPrint;

const verse = @import("verse");
const abx = verse.abx;
const Frame = verse.Frame;
const Template = verse.template;
const Routes = verse.Router;
const Error = Routes.Error;
const ROUTE = Routes.ROUTE;
const S = Template.Structs;

const Delta = @import("../types.zig").Delta;
