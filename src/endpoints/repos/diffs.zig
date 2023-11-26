const std = @import("std");

const DOM = Endpoint.DOM;
const HTML = Endpoint.HTML;
const Endpoint = @import("../../endpoint.zig");
const Context = @import("../../context.zig");
const Response = Endpoint.Response;
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;

const GET = Endpoint.Router.Methods.GET;
const POST = Endpoint.Router.Methods.POST;

pub const routes = [_]Endpoint.Router.MatchRouter{
    .{ .name = "", .methods = GET, .match = .{ .call = default } },
    .{ .name = "new", .methods = GET, .match = .{ .call = new } },
    .{ .name = "new", .methods = POST, .match = .{ .call = newPost } },
};

fn isHex(input: []const u8) ?usize {
    for (input) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return std.fmt.parseInt(usize, input, 16) catch null;
}

fn diffValidForRepo(repo: []const u8, diff: usize) bool {
    _ = repo;
    return diff > 0;
}

pub fn router(ctx: *Context) Error!Endpoint.Endpoint {
    std.debug.assert(std.mem.eql(u8, "diffs", ctx.uri.next().?));
    const verb = ctx.uri.peek() orelse return Endpoint.Router.router(ctx, &routes);

    const repo_name = "none";
    if (isHex(verb)) |dnum| {
        if (diffValidForRepo(repo_name, dnum))
            return view;
    }

    return Endpoint.Router.router(ctx, &routes);
}

fn new(r: *Response, _: *UriIter) Error!void {
    var tmpl = Template.find("diffs.html");
    tmpl.init(r.alloc);

    var dom = DOM.new(r.alloc);
    dom = dom.open(HTML.element("intro", null, null));
    dom.push(HTML.text("New Pull Request"));
    dom = dom.close();
    var fattr = try r.alloc.dupe(HTML.Attr, &[_]HTML.Attr{
        .{ .key = "action", .value = "new" },
        .{ .key = "method", .value = "POST" },
    });
    dom = dom.open(HTML.form(null, fattr));

    dom.push(HTML.input(null, null));
    dom.push(HTML.input(null, null));
    dom.push(HTML.textarea(null, null));

    dom = dom.close();

    _ = try tmpl.addElements(r.alloc, "diff", dom.done());
    r.sendTemplate(&tmpl) catch unreachable;
}

fn newPost(r: *Response, _: *UriIter) Error!void {
    var tmpl = Template.find("diffs.html");
    tmpl.init(r.alloc);
    try tmpl.addVar("diff", "new data attempting");
    r.sendTemplate(&tmpl) catch unreachable;
}

fn view(r: *Response, _: *UriIter) Error!void {
    var tmpl = Template.find("diffs.html");
    tmpl.init(r.alloc);
    try tmpl.addVar("diff", "View diff number");
    r.sendTemplate(&tmpl) catch unreachable;
}

fn default(r: *Response, _: *UriIter) Error!void {
    var tmpl = Template.find("diffs.html");
    tmpl.init(r.alloc);
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;
    r.start() catch return Error.Unknown;
    r.send(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}
