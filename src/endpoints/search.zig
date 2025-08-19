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

fn custom(ctx: *Frame, search_str: []const u8) Error!void {
    var rules = std.ArrayList(Delta.SearchRule).init(ctx.alloc);

    var itr = splitScalar(u8, search_str, ' ');
    while (itr.next()) |r_line| {
        var line = r_line;
        line = std.mem.trim(u8, line, " ");
        if (line.len == 0) continue;
        const inverse = line[0] == '-';
        if (inverse) {
            line = line[1..];
        }
        if (std.mem.indexOf(u8, line, ":")) |i| {
            try rules.append(Delta.SearchRule{
                .subject = line[0..i],
                .match = line[i + 1 ..],
                .inverse = inverse,
            });
        } else {
            try rules.append(Delta.SearchRule{
                .subject = "",
                .match = line,
                .inverse = inverse,
            });
        }
    }

    for (rules.items) |rule| {
        if (false)
            std.debug.print("rule = {s} : {s}\n", .{ rule.subject, rule.match });
    }

    var d_list = std.ArrayList(S.DeltaList).init(ctx.alloc);
    var search_results = Delta.search(ctx.alloc, rules.items);
    while (search_results.next(ctx.alloc) catch null) |next_| {
        var d: Delta = next_;
        const cmtsmeta = d.countComments();

        _ = d.loadThread(ctx.alloc) catch return error.Unknown;
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

    const meta_head = Template.Structs.MetaHeadHtml{
        .open_graph = .{},
    };
    const btns = [1]Template.Structs.NavButtons{.{
        .name = "inbox",
        .extra = 0,
        .url = "/inbox",
    }};

    var page = DeltaListPage.init(.{
        .meta_head = meta_head,
        .body_header = .{ .nav = .{
            .nav_buttons = &btns,
        } },
        .delta_list = try d_list.toOwnedSlice(),
        .search = verse.abx.Html.cleanAlloc(ctx.alloc, search_str) catch unreachable,
    });

    try ctx.sendPage(&page);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const splitScalar = std.mem.splitScalar;
const allocPrint = std.fmt.allocPrint;

const verse = @import("verse");
const Frame = verse.Frame;
const Template = verse.template;
const Routes = verse.Router;
const Error = Routes.Error;
const ROUTE = Routes.ROUTE;
const S = Template.Structs;

const Delta = @import("../types.zig").Delta;
