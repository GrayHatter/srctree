const std = @import("std");

const Allocator = std.mem.Allocator;

const Endpoint = @import("../endpoint.zig");
const Response = Endpoint.Response;
const Request = Endpoint.Request;
const HTML = Endpoint.HTML;
//const elm = HTML.element;
const DOM = Endpoint.DOM;
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;

const git = @import("../git.zig");

const endpoints = [_]Endpoint.Router.MatchRouter{
    .{
        .name = "",
        .methods = Endpoint.Router.Methods.GET | Endpoint.Router.Methods.POST,
        .match = .{ .call = view },
    },
    .{
        .name = "post",
        .methods = Endpoint.Router.Methods.GET | Endpoint.Router.Methods.POST,
        .match = .{ .call = view },
    },
};

pub fn router(uri: *UriIter, method: Request.Methods) Error!Endpoint.Endpoint {
    return Endpoint.Router.router(uri, method, &endpoints);
}

fn createRepo(a: Allocator, reponame: []const u8) !void {
    var dn_buf: [2048]u8 = undefined;
    var dir = try std.fmt.bufPrint(&dn_buf, "repos/{}", .{reponame});

    var actions = git.Actions{
        .alloc = a,
        .cwd_dir = std.fs.cwd(),
    };

    _ = try actions.gitInit(dir, .{});
}

fn default(r: *Response, _: *UriIter) Error!void {
    var dom = DOM.new(r.alloc);
    const action = "/admin/post";
    dom = dom.open(HTML.form(null, &[_]HTML.Attr{
        HTML.Attr{ .key = "method", .value = "POST" },
        HTML.Attr{ .key = "action", .value = action },
    }));
    dom = dom.open(HTML.element("button", null, &[_]HTML.Attr{
        HTML.Attr{ .key = "name", .value = "new repo" },
    }));
    dom.push(HTML.element("_text", "create repo", null));

    dom = dom.close();
    dom = dom.close();

    var form = dom.done();

    var tmpl = Template.find("admin.html");
    tmpl.init(r.alloc);
    _ = tmpl.addElements(r.alloc, "form", form) catch unreachable;
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;
    r.start() catch return Error.Unknown;
    r.write(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}

fn newRepo(r: *Response, _: *UriIter) Error!void {
    var dom = DOM.new(r.alloc);
    const action = "/admin/post";
    dom = dom.open(HTML.form(null, &[_]HTML.Attr{
        HTML.Attr{ .key = "method", .value = "POST" },
        HTML.Attr{ .key = "action", .value = action },
    }));
    dom.push(HTML.element("input", null, &[_]HTML.Attr{
        HTML.Attr{ .key = "name", .value = "new repo" },
        HTML.Attr{ .key = "value", .value = "repo name" },
    }));

    dom = dom.close();

    var form = dom.done();

    var tmpl = Template.find("admin.html");
    tmpl.init(r.alloc);
    _ = tmpl.addElements(r.alloc, "form", form) catch unreachable;
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;
    r.start() catch return Error.Unknown;
    r.write(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}

fn view(r: *Response, uri: *UriIter) Error!void {
    if (r.post_data) |pd| {
        std.debug.print("{any}\n", .{pd.items});
        return newRepo(r, uri);
    }
    return default(r, uri);
}
