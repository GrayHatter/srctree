const std = @import("std");

const Allocator = std.mem.Allocator;

const Endpoint = @import("../endpoint.zig");
const Context = @import("../context.zig");
const Response = Endpoint.Response;
const Request = Endpoint.Request;
const HTML = Endpoint.HTML;
//const elm = HTML.element;
const DOM = Endpoint.DOM;
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;

const git = @import("../git.zig");

const GET = Endpoint.Router.Methods.GET;
const POST = Endpoint.Router.Methods.POST;

const endpoints = [_]Endpoint.Router.MatchRouter{
    .{ .name = "", .methods = GET | POST, .match = .{ .call = view } },
    .{ .name = "post", .methods = GET | POST, .match = .{ .call = view } },
    .{ .name = "new-repo", .methods = GET, .match = .{ .call = newRepo } },
    .{ .name = "new-repo", .methods = POST, .match = .{ .call = postNewRepo } },
};

pub fn router(ctx: *Context) Error!Endpoint.Endpoint {
    return Endpoint.Router.router(ctx, &endpoints);
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
    if (!r.request.auth.valid()) return error.Abusive;
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
    r.send(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}

fn postNewRepo(r: *Response, _: *UriIter) Error!void {
    if (!r.request.auth.valid()) return error.Abusive;
    // TODO ini repo dir
    var valid = r.post_data.?.validator();
    var rname = valid.require("repo name") catch return error.Unknown;

    for (rname.value) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (c == '-' or c == '_') continue;
        return error.Abusive;
    }

    std.debug.print("creating {s}\n", .{rname.value});
    var buf: [2048]u8 = undefined;
    var dir_name = std.fmt.bufPrint(&buf, "repos/{s}", .{rname.value}) catch return error.Unknown;
    var new_repo = git.Repo.createNew(r.alloc, dir_name) catch return error.Unknown;

    std.debug.print("creating {any}\n", .{new_repo});

    var dom = DOM.new(r.alloc);
    const action = "/admin/new-repo";
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
    r.send(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}

fn newRepo(r: *Response, _: *UriIter) Error!void {
    if (!r.request.auth.valid()) return error.Abusive;
    var dom = DOM.new(r.alloc);
    const action = "/admin/new-repo";
    dom = dom.open(HTML.form(null, &[_]HTML.Attr{
        HTML.Attr{ .key = "method", .value = "POST" },
        HTML.Attr{ .key = "action", .value = action },
    }));
    dom.push(HTML.element("input", null, &[_]HTML.Attr{
        HTML.Attr{ .key = "name", .value = "repo name" },
        HTML.Attr{ .key = "value", .value = "new_repo" },
    }));

    dom = dom.close();

    var form = dom.done();

    var tmpl = Template.find("admin.html");
    tmpl.init(r.alloc);
    _ = tmpl.addElements(r.alloc, "form", form) catch unreachable;
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;
    r.start() catch return Error.Unknown;
    r.send(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}

fn view(r: *Response, uri: *UriIter) Error!void {
    if (!r.request.auth.valid()) return error.Abusive;
    if (r.post_data) |pd| {
        std.debug.print("{any}\n", .{pd.items});
        return newRepo(r, uri);
    }
    return default(r, uri);
}
