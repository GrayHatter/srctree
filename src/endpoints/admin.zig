pub const verse_name = .admin;

pub const verse_routes = [_]Route.Match{
    Route.ANY("post", index),
    Route.ROUTE("new-repo", newRepo),
    Route.POST("new-repo", postNewRepo),
    Route.GET("clone-upstream", cloneUpstream),
    Route.POST("clone-upstream", postCloneUpstream),
};

pub fn index(ctx: *Frame) Error!void {
    try ctx.requireValidUser();
    if (ctx.request.data.post) |pd| {
        std.debug.print("{any}\n", .{pd.items});
        return newRepo(ctx);
    }
    return default(ctx);
}

fn createRepo(a: Allocator, reponame: []const u8) !void {
    var dn_buf: [2048]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dn_buf, "repos/{}", .{reponame});

    var agent = git.Agent{
        .alloc = a,
        .cwd = null,
    };

    _ = try agent.gitInit(dir, .{});
}

const AdminPage = template.PageData("admin.html");

fn default(ctx: *Frame) Error!void {
    try ctx.requireValidUser();
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

    const list = try ctx.alloc.alloc([]u8, form.len);
    for (list, form) |*l, e| l.* = try std.fmt.allocPrint(ctx.alloc, "{}", .{e});
    const value = try std.mem.join(ctx.alloc, "", list);
    _ = value;

    var page = AdminPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{ .nav_buttons = &.{} } },
        .active_admin = .settings,
    });
    try ctx.sendPage(&page);
}

const CloneUpstreamPage = template.PageData("admin/clone-upstream.html");
fn cloneUpstream(ctx: *Frame) Error!void {
    try ctx.requireValidUser();
    var page = CloneUpstreamPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{ .nav_buttons = &.{} } },
        .post_error = null,
    });
    try ctx.sendPage(&page);
}

const CloneUpstreamReq = struct {
    repo_uri: []const u8,
};

fn postCloneUpstream(ctx: *Frame) Error!void {
    try ctx.requireValidUser();

    var page = CloneUpstreamPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{ .nav_buttons = &.{} } },
        .post_error = null,
    });

    const udata = ctx.request.data.post.?.validate(CloneUpstreamReq) catch return error.DataInvalid;
    std.debug.print("repo uri {s}\n", .{udata.repo_uri});
    var nameitr = std.mem.splitBackwardsScalar(u8, udata.repo_uri, '/');
    const name = nameitr.first();
    std.debug.print("repo uri {s}\n", .{name});
    // TODO sanitize requested repo name
    const dir = std.fs.cwd().openDir("repos", .{}) catch |err| {
        page.data.post_error = .{ .err_str = @errorName(err) };
        return try ctx.sendPage(&page);
    };

    var agent = git.Agent{
        .alloc = ctx.alloc,
        .cwd = dir,
    };
    std.debug.print("fork bare {s}\n", .{
        agent.forkRemote(udata.repo_uri, name) catch |err| {
            page.data.post_error = .{ .err_str = @errorName(err) };
            return try ctx.sendPage(&page);
        },
    });

    // TODO redirect to new repo
    return ctx.redirect("/repos", .see_other) catch unreachable;
}

fn postNewRepo(ctx: *Frame) Error!void {
    try ctx.requireValidUser();

    // TODO ini repo dir
    var valid = if (ctx.request.data.post) |p|
        p.validator()
    else
        return error.DataInvalid;
    const rname = valid.require("repo name") catch return error.Unknown;

    for (rname.value) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        if (c == '-' or c == '_') continue;
        return error.Abuse;
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
    const list = try ctx.alloc.alloc([]u8, form.len);
    for (list, form) |*l, e| l.* = try std.fmt.allocPrint(ctx.alloc, "{}", .{e});
    const value = try std.mem.join(ctx.alloc, "", list);
    _ = value;

    var page = AdminPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{ .nav_buttons = &.{} } },
        .active_admin = .settings,
    });
    try ctx.sendPage(&page);
}

fn newRepo(ctx: *Frame) Error!void {
    try ctx.requireValidUser();
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
    const list = try ctx.alloc.alloc([]u8, form.len);
    for (list, form) |*l, e| l.* = try std.fmt.allocPrint(ctx.alloc, "{}", .{e});
    const value = try std.mem.join(ctx.alloc, "", list);
    _ = value;

    var page = AdminPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{ .nav_buttons = &.{} } },
        .active_admin = .settings,
    });
    try ctx.sendPage(&page);
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const verse = @import("verse");
const Frame = verse.Frame;
const Route = verse.Router;
const template = verse.template;
const S = template.Structs;
const HTML = template.html;
const DOM = HTML.DOM;

const Error = Route.Error;

const git = @import("../git.zig");
