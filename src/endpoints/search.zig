const std = @import("std");
const Allocator = std.mem.Allocator;

const HTML = Endpoint.HTML;
const Endpoint = @import("../endpoint.zig");
const Context = @import("../context.zig");
const Deltas = @import("../types/deltas.zig");
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const ROUTE = Endpoint.Router.ROUTE;

const UserData = @import("../user-data.zig").UserData;
const Bleach = @import("../bleach.zig");

pub const routes = [_]Endpoint.Router.MatchRouter{
    ROUTE("", search),
    ROUTE("search", search),
};

pub fn router(ctx: *Context) Error!Endpoint.Router.Callable {
    return Endpoint.Router.router(ctx, &routes);
}

const SearchReq = struct {
    q: []const u8,
};

fn search(ctx: *Context) Error!void {
    var tmpl = Template.find("deltalist.html");
    tmpl.init(ctx.alloc);

    const udata = UserData(SearchReq).init(ctx.req_data.query_data) catch return error.BadData;

    std.debug.print("query {s}\n", .{udata.q});
    var rules = std.ArrayList(Deltas.SearchRule).init(ctx.alloc);

    var itr = std.mem.split(u8, udata.q, " ");
    while (itr.next()) |r_line| {
        var line = r_line;
        line = std.mem.trim(u8, line, " ");
        if (line.len == 0) continue;
        const inverse = line[0] == '-';
        if (inverse) {
            line = line[1..];
        }
        if (std.mem.indexOf(u8, line, ":")) |i| {
            try rules.append(Deltas.SearchRule{
                .subject = line[0..i],
                .match = line[i + 1 ..],
                .inverse = inverse,
            });
        } else {
            try rules.append(Deltas.SearchRule{
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
    var search_results = Deltas.search(ctx.alloc, rules.items);
    while (search_results.next(ctx.alloc)) |next_| {
        if (next_) |next| {
            var c = Template.Context.init(ctx.alloc);
            const builder = next.builder();
            builder.build(ctx.alloc, &c) catch unreachable;
            try list.append(c);
        } else break;
    } else |_| return error.Unknown;

    try tmpl.ctx.?.putBlock("list", list.items);
    try tmpl.ctx.?.put(
        "search",
        Bleach.sanitizeAlloc(ctx.alloc, udata.q, .{}) catch unreachable,
    );
    try ctx.sendTemplate(&tmpl);
}
