const std = @import("std");

const DOM = Endpoint.DOM;
const HTML = Endpoint.HTML;
const Endpoint = @import("../endpoint.zig");
const Context = Endpoint.Context;
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;

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

    var tmpl = Template.find("actionable.html");
    tmpl.init(ctx.alloc);
    _ = tmpl.addElements(ctx.alloc, "todos", data) catch unreachable;
    ctx.sendTemplate(&tmpl) catch unreachable;
}

pub fn todo(ctx: *Context) Error!void {
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

    var tmpl = Template.find("actionable.html");
    tmpl.init(ctx.alloc);
    _ = tmpl.addElements(ctx.alloc, "todos", data) catch unreachable;
    ctx.sendTemplate(&tmpl) catch unreachable;
}
