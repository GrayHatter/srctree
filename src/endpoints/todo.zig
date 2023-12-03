const std = @import("std");

const DOM = Endpoint.DOM;
const HTML = Endpoint.HTML;
const Endpoint = @import("../endpoint.zig");
const Context = Endpoint.Context;
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;

const GET = Endpoint.Router.Methods.GET;
const POST = Endpoint.Router.Methods.POST;

pub const endpoints = [_]Endpoint.Router.MatchRouter{
    .{ .name = "", .methods = GET, .match = .{ .call = default } },
};

fn default(ctx: *Context) Error!void {
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

    var data = dom.done();

    var tmpl = Template.find("todo.html");
    tmpl.init(ctx.alloc);
    _ = tmpl.addElements(ctx.alloc, "todos", data) catch unreachable;
    var page = tmpl.buildFor(ctx.alloc, ctx) catch unreachable;
    ctx.response.start() catch return Error.Unknown;
    ctx.response.send(page) catch return Error.Unknown;
    ctx.response.finish() catch return Error.Unknown;
}
