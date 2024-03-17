const std = @import("std");
const Allocator = std.mem.Allocator;

const HTML = Endpoint.HTML;
const Endpoint = @import("../endpoint.zig");
const Context = @import("../context.zig");
const Deltas = @import("../types/deltas.zig");
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const ROUTE = Endpoint.Router.ROUTE;

const Bleach = @import("../bleach.zig");

pub const routes = [_]Endpoint.Router.MatchRouter{
    ROUTE("", search),
    ROUTE("search", search),
};

pub fn router(ctx: *Context) Error!Endpoint.Router.Callable {
    return Endpoint.Router.router(ctx, &routes);
}

fn search(ctx: *Context) Error!void {
    var tmpl = Template.find("deltalist.html");
    tmpl.init(ctx.alloc);

    var v = ctx.usr_data.query_data.validator();
    const q = v.require("q") catch |err| {
        std.debug.print("no q\n", .{});
        return err;
    };

    std.debug.print("query {s}\n", .{q.value});

    const rules = [_]Deltas.SearchRule{
        //.{ .subject = "repo", .match = "srctree2" },
    };

    var list = std.ArrayList(Template.Context).init(ctx.alloc);
    var itr = Deltas.search(ctx.alloc, &rules);
    while (itr.next(ctx.alloc)) |next_| {
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
        Bleach.sanitizeAlloc(ctx.alloc, q.value, .{}) catch unreachable,
    );
    ctx.sendTemplate(&tmpl) catch return error.Unknown;
}
