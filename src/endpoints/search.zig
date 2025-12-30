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
    return custom(ctx, "owner:me is:open");
}

pub fn index(ctx: *Frame) Error!void {
    const udata = ctx.request.data.query.validate(SearchReq) catch return error.DataInvalid;
    const query_str = udata.q orelse "";
    return custom(ctx, query_str);
}

const DeltaListPage = Template.PageData("delta-list.html");

pub fn genRules(search_str: []const u8, a: Allocator) !ArrayList(Delta.SearchRule) {
    var rules: ArrayList(Delta.SearchRule) = .{};
    {
        var itr = splitScalar(u8, search_str, ' ');
        while (itr.next()) |r_line| {
            var line = r_line;
            line = std.mem.trim(u8, line, " ");
            if (line.len == 0) continue;
            try rules.append(a, .parse(line));
        }
    }
    return rules;
}

fn custom(f: *Frame, search_str: []const u8) Error!void {
    const rules = try genRules(search_str, f.alloc);
    for (rules.items) |rule| {
        log.warn("rule = {f}", .{rule});
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

    var page = DeltaListPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = f.response_data.get(S.BodyHeaderHtml).?.*,
        .delta_list = d_list.items,
        .search = allocPrint(f.alloc, "{f}", .{abx.Html{ .text = search_str }}) catch unreachable,
    });

    try f.sendPage(&page);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const log = std.log.scoped(.search);
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
