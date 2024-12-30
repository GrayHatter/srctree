const std = @import("std");

const Allocator = std.mem.Allocator;

const Verse = @import("verse");
const Route = Verse.Router;
const Template = Verse.Template;
const HTML = Verse.html;
const DOM = HTML.DOM;

const Error = Route.Error;
const UriIter = Route.UriIter;

const git = @import("../git.zig");

pub const endpoints = [_]Route.Match{
    Route.ROUTE("", view),
    Route.POST("post", view),
    Route.ROUTE("new-repo", newRepo),
    Route.POST("new-repo", postNewRepo),
    Route.ROUTE("clone-upstream", cloneUpstream),
    Route.POST("clone-upstream", postCloneUpstream),
};

fn createRepo(a: Allocator, reponame: []const u8) !void {
    var dn_buf: [2048]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dn_buf, "repos/{}", .{reponame});

    var agent = git.Agent{
        .alloc = a,
        .cwd = null,
    };

    _ = try agent.gitInit(dir, .{});
}

const AdminPage = Template.PageData("admin.html");

/// TODO fix me
const btns = [1]Template.Structs.NavButtons{.{ .name = "inbox", .extra = 0, .url = "/inbox" }};

fn default(ctx: *Verse.Frame) Error!void {
    //try ctx.auth.requireValid();
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

    var page = AdminPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .nav = .{ .nav_buttons = &btns } },
        .form = value,
    });
    try ctx.sendPage(&page);
}

fn cloneUpstream(ctx: *Verse.Frame) Error!void {
    //try ctx.auth.requireValid();
    var dom = DOM.new(ctx.alloc);
    const action = "/admin/clone-upstream";
    dom = dom.open(HTML.form(null, &[_]HTML.Attr{
        HTML.Attr{ .key = "method", .value = "POST" },
        HTML.Attr{ .key = "action", .value = action },
    }));
    dom.push(HTML.element("input", null, &[_]HTML.Attr{
        HTML.Attr{ .key = "name", .value = "repo_uri" },
        HTML.Attr{ .key = "value", .value = "https://srctree/reponame" },
    }));
    dom = dom.close();
    const form = dom.done();
    const list = try ctx.alloc.alloc([]u8, form.len);
    for (list, form) |*l, e| l.* = try std.fmt.allocPrint(ctx.alloc, "{}", .{e});
    const value = try std.mem.join(ctx.alloc, "", list);

    var page = AdminPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{
            .nav = .{
                .nav_buttons = &btns,
            },
        },
        .form = value,
    });
    try ctx.sendPage(&page);
}

const CloneUpstreamReq = struct {
    repo_uri: []const u8,
};

fn postCloneUpstream(ctx: *Verse.Frame) Error!void {
    //try ctx.auth.requireValid();

    const udata = ctx.request.data.post.?.validate(CloneUpstreamReq) catch return error.BadData;
    std.debug.print("repo uri {s}\n", .{udata.repo_uri});
    var nameitr = std.mem.splitBackwardsScalar(u8, udata.repo_uri, '/');
    const name = nameitr.first();
    std.debug.print("repo uri {s}\n", .{name});

    const dir = std.fs.cwd().openDir("repos", .{}) catch return error.Unknown;
    var agent = git.Agent{
        .alloc = ctx.alloc,
        .cwd = dir,
    };
    std.debug.print("fork bare {s}\n", .{
        agent.forkRemote(udata.repo_uri, name) catch return error.Unknown,
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
    const list = try ctx.alloc.alloc([]u8, form.len);
    for (list, form) |*l, e| l.* = try std.fmt.allocPrint(ctx.alloc, "{}", .{e});
    const value = try std.mem.join(ctx.alloc, "", list);

    var page = AdminPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{
            .nav = .{
                .nav_buttons = &btns,
            },
        },
        .form = value,
    });
    try ctx.sendPage(&page);
}

fn postNewRepo(ctx: *Verse.Frame) Error!void {
    //try ctx.auth.requireValid();
    // TODO ini repo dir
    var valid = if (ctx.request.data.post) |p|
        p.validator()
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
    const list = try ctx.alloc.alloc([]u8, form.len);
    for (list, form) |*l, e| l.* = try std.fmt.allocPrint(ctx.alloc, "{}", .{e});
    const value = try std.mem.join(ctx.alloc, "", list);

    var page = AdminPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{
            .nav = .{
                .nav_buttons = &btns,
            },
        },
        .form = value,
    });
    try ctx.sendPage(&page);
}

fn newRepo(ctx: *Verse.Frame) Error!void {
    //try ctx.auth.requireValid();
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

    var page = AdminPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .nav = .{ .nav_buttons = &btns } },
        .form = value,
    });
    try ctx.sendPage(&page);
}

fn view(ctx: *Verse.Frame) Error!void {
    //try ctx.auth.requireValid();
    if (ctx.request.data.post) |pd| {
        std.debug.print("{any}\n", .{pd.items});
        return newRepo(ctx);
    }
    return default(ctx);
}
