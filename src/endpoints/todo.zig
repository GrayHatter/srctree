const std = @import("std");

const DOM = Endpoint.DOM;
const HTML = Endpoint.HTML;
const Endpoint = @import("../endpoint.zig");
const Response = Endpoint.Response;
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;

const GET = Endpoint.Router.Methods.GET;
const POST = Endpoint.Router.Methods.POST;

pub const endpoints = [_]Endpoint.Router.MatchRouter{
    .{ .name = "", .methods = GET, .match = .{ .call = default } },
};

fn default(r: *Response, _: *UriIter) Error!void {
    var dom = DOM.new(r.alloc);
    dom.push(HTML.element("search", null, null));

    dom = dom.open(HTML.element("issues", null, null));
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
    tmpl.init(r.alloc);
    _ = tmpl.addElements(r.alloc, "todos", data) catch unreachable;
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;
    r.start() catch return Error.Unknown;
    r.send(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}
