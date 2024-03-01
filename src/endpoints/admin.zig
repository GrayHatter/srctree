const std = @import("std");

const Allocator = std.mem.Allocator;

const Endpoint = @import("../endpoint.zig");
const Context = @import("../context.zig");
const Route = @import("../routes.zig");
const HTML = Endpoint.HTML;
//const elm = HTML.element;
const DOM = Endpoint.DOM;
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;

const git = @import("../git.zig");

const GET = Endpoint.Router.Methods.GET;
const POST = Endpoint.Router.Methods.POST;

pub const endpoints = [_]Route.MatchRouter{
    Route.ROUTE("", view),
    Route.ROUTE("post", view),
    Route.ROUTE("new-repo", newRepo),
    Route.post("new-repo", postNewRepo),
    Route.ROUTE("clone-upstream", cloneUpstream),
    Route.post("clone-upstream", postCloneUpstream),
};

fn createRepo(a: Allocator, reponame: []const u8) !void {
    var dn_buf: [2048]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dn_buf, "repos/{}", .{reponame});

    var actions = git.Actions{
        .alloc = a,
        .cwd = null,
    };

    _ = try actions.gitInit(dir, .{});
}

fn default(ctx: *Context) Error!void {
    try ctx.response.request.auth.validOrError();
    var dom = DOM.new(ctx.alloc);
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

    const form = dom.done();

    var tmpl = Template.find("admin.html");
    tmpl.init(ctx.alloc);
    _ = tmpl.addElements(ctx.alloc, "form", form) catch unreachable;
    try ctx.sendTemplate(&tmpl);
}

fn cloneUpstream(ctx: *Context) Error!void {
    try ctx.response.request.auth.validOrError();
    var dom = DOM.new(ctx.alloc);
    const action = "/admin/clone-upstream";
    dom = dom.open(HTML.form(null, &[_]HTML.Attr{
        HTML.Attr{ .key = "method", .value = "POST" },
        HTML.Attr{ .key = "action", .value = action },
    }));
    dom.push(HTML.element("input", null, &[_]HTML.Attr{
        HTML.Attr{ .key = "name", .value = "repo uri" },
        HTML.Attr{ .key = "value", .value = "https://srctree/reponame" },
    }));
    dom = dom.close();
    const form = dom.done();

    var tmpl = Template.find("admin.html");
    tmpl.init(ctx.alloc);
    _ = tmpl.addElements(ctx.alloc, "form", form) catch unreachable;
    try ctx.sendTemplate(&tmpl);
}

fn postCloneUpstream(ctx: *Context) Error!void {
    try ctx.response.request.auth.validOrError();

    var valid = ctx.response.usr_data.?.post_data.?.validator();
    const ruri = valid.require("repo uri") catch return error.Unknown;
    std.debug.print("repo uri {s}\n", .{ruri.value});
    var nameitr = std.mem.splitBackwards(u8, ruri.value, "/");
    const name = nameitr.first();
    std.debug.print("repo uri {s}\n", .{name});

    const dir = std.fs.cwd().openDir("repos", .{}) catch return error.Unknown;
    var act = git.Actions{
        .alloc = ctx.alloc,
        .cwd = dir,
    };
    std.debug.print("fork bare {s}\n", .{
        act.forkRemote(ruri.value, name) catch return error.Unknown,
    });

    var dom = DOM.new(ctx.alloc);
    const action = "/admin/clone-upstream";
    dom = dom.open(HTML.form(null, &[_]HTML.Attr{
        HTML.Attr{ .key = "method", .value = "POST" },
        HTML.Attr{ .key = "action", .value = action },
    }));
    dom.push(HTML.element("input", null, &[_]HTML.Attr{
        HTML.Attr{ .key = "name", .value = "repo uri" },
        HTML.Attr{ .key = "value", .value = "https://srctree/reponame" },
    }));
    dom = dom.close();
    const form = dom.done();

    var tmpl = Template.find("admin.html");
    tmpl.init(ctx.alloc);
    _ = tmpl.addElements(ctx.alloc, "form", form) catch unreachable;
    try ctx.sendTemplate(&tmpl);
}

fn postNewRepo(ctx: *Context) Error!void {
    try ctx.request.auth.validOrError();
    // TODO ini repo dir
    var valid = if (ctx.response.usr_data) |usr|
        if (usr.post_data) |p|
            p.validator()
        else
            return error.Unknown
    else
        return error.Unknown;
    const rname = valid.require("repo name") catch return error.Unknown;

    for (rname.value) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (c == '-' or c == '_') continue;
        return error.Abusive;
    }

    std.debug.print("creating {s}\n", .{rname.value});
    var buf: [2048]u8 = undefined;
    const dir_name = std.fmt.bufPrint(&buf, "repos/{s}", .{rname.value}) catch return error.Unknown;

    if (std.fs.cwd().openDir(dir_name, .{})) |_| return error.Unknown else |_| {}

    const new_repo = git.Repo.createNew(ctx.alloc, std.fs.cwd(), dir_name) catch return error.Unknown;

    std.debug.print("creating {any}\n", .{new_repo});

    var dom = DOM.new(ctx.alloc);
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
    const form = dom.done();

    var tmpl = Template.find("admin.html");
    tmpl.init(ctx.alloc);
    _ = tmpl.addElements(ctx.alloc, "form", form) catch unreachable;
    try ctx.sendTemplate(&tmpl);
}

fn newRepo(ctx: *Context) Error!void {
    try ctx.request.auth.validOrError();
    var dom = DOM.new(ctx.alloc);
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

    const form = dom.done();

    var tmpl = Template.find("admin.html");
    tmpl.init(ctx.alloc);
    _ = tmpl.addElements(ctx.alloc, "form", form) catch unreachable;
    try ctx.sendTemplate(&tmpl);
}

fn view(ctx: *Context) Error!void {
    try ctx.request.auth.validOrError();
    if (ctx.response.usr_data) |usr| if (usr.post_data) |pd| {
        std.debug.print("{any}\n", .{pd.items});
        return newRepo(ctx);
    };
    return default(ctx);
}
