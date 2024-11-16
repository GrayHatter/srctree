const std = @import("std");
const Allocator = std.mem.Allocator;

const Context = @import("../context.zig");
const Delta = @import("../types.zig").Delta;
const Template = @import("../template.zig");
const Route = @import("../routes.zig");
const Error = Route.Error;
const ROUTE = Route.ROUTE;

const Bleach = @import("../bleach.zig");

pub const routes = [_]Route.Match{
    ROUTE("", search),
    ROUTE("search", search),
    ROUTE("inbox", inbox),
};

pub fn router(ctx: *Context) Error!Route.Callable {
    return Route.router(ctx, &routes);
}

const SearchReq = struct {
    q: ?[]const u8,
};

fn inbox(ctx: *Context) Error!void {
    return custom(ctx, "owner:me");
}

fn search(ctx: *Context) Error!void {
    const udata = ctx.reqdata.query.validate(SearchReq) catch return error.BadData;

    const query_str = udata.q orelse "null";
    std.debug.print("query {s}\n", .{query_str});

    return custom(ctx, query_str);
}

fn custom(ctx: *Context, search_str: []const u8) Error!void {
    var tmpl = Template.find("delta-list.html");

    var rules = std.ArrayList(Delta.SearchRule).init(ctx.alloc);

    var itr = std.mem.split(u8, search_str, " ");
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
        std.debug.print("rule = {s} : {s}\n", .{ rule.subject, rule.match });
    }

    var list = std.ArrayList(Template.Context).init(ctx.alloc);
    var search_results = Delta.search(ctx.alloc, rules.items);
    while (search_results.next(ctx.alloc) catch return error.Unknown) |next_| {
        var next: Delta = next_;

        if (next.loadThread(ctx.alloc)) |*thread| {
            _ = thread.*.loadComments(ctx.alloc) catch return error.Unknown;
        } else |_| continue;
        try list.append(try next.toContext(ctx.alloc));
    }

    try ctx.putContext("DeltaList", .{ .block = list.items });
    try ctx.putContext(
        "Search",
        .{ .slice = Bleach.sanitizeAlloc(ctx.alloc, search_str, .{}) catch unreachable },
    );
    try ctx.sendTemplate(&tmpl);
}
