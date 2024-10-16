const std = @import("std");

const DOM = @import("../dom.zig");
const HTML = @import("../html.zig");
const Context = @import("../context.zig");
const Template = @import("../template.zig");
const Route = @import("../routes.zig");
const UriIter = Route.UriIter;
const Types = @import("../types.zig");
const Deltas = Types.Delta;
const Error = Route.Error;

pub fn diffs(ctx: *Context) Error!void {
    var dom = DOM.new(ctx.alloc);
    dom.push(HTML.element("search", null, null));

    dom = dom.open(HTML.element("actionable", null, null));
    for (0..5) |_| {
        dom = dom.open(HTML.element("issue", null, null));
        dom = dom.open(HTML.element("desc", null, null));
        dom.push(HTML.text("this is a issue"));
        dom = dom.close();
        dom = dom.close();
    }
    dom = dom.close();

    const data = dom.done();

    var tmpl = Template.find("deltalist.html");
    _ = ctx.addElements(ctx.alloc, "todos", data) catch unreachable;
    ctx.sendTemplate(&tmpl) catch unreachable;
}

pub fn todo(ctx: *Context) Error!void {
    var tmpl = Template.find("deltalist.html");

    const tmpl_ctx_list = std.ArrayList(Template.Context).init(ctx.alloc);
    _ = tmpl_ctx_list;

    //var search_results = Deltas.search(ctx.alloc, rules.items);

    //for (0..last) |i| {
    //    var d = Deltas.open(ctx.alloc, rd.name, i) catch continue orelse continue;
    //    if (!std.mem.eql(u8, d.repo, rd.name) or d.attach != .issue) {
    //        d.raze(ctx.alloc);
    //        continue;
    //    }

    //    const delta_ctx = &tmpl_ctx[end];
    //    delta_ctx.* = Template.Context.init(ctx.alloc);
    //    const builder = d.builder();
    //    builder.build(ctx.alloc, delta_ctx) catch unreachable;
    //    _ = d.loadThread(ctx.alloc) catch unreachable;
    //    if (d.getComments(ctx.alloc)) |cmts| {
    //        try delta_ctx.put(
    //            "comments_icon",
    //            try std.fmt.allocPrint(ctx.alloc, "<span class=\"icon\">\xee\xa0\x9c {}</span>", .{cmts.len}),
    //        );
    //    } else |_| unreachable;
    //    end += 1;
    //    continue;
    //}
    //var tmpl = Template.find("deltalist.html");
    //try tmpl.ctx.?.putBlock("list", tmpl_ctx[0..end]);

    //var default_search_buf: [0xFF]u8 = undefined;
    //const def_search = try std.fmt.bufPrint(&default_search_buf, "is:issue repo:{s} ", .{rd.name});
    //try tmpl.ctx.?.put("search", def_search);

    //try tmpl.ctx.?.push("todos", );
    ctx.sendTemplate(&tmpl) catch unreachable;
}
