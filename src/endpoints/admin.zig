pub const verse_name = .admin;

pub const verse_routes = [_]Route.Match{
    Route.GET("settings", settings),
    Route.GET("remotes", remotes),
    Route.POST("settings", settingsPost),
};

pub const verse_endpoints = verse.Endpoints(.{Repo});

const AdminPage = template.PageData("admin.html");

pub fn index(ctx: *Frame) Error!void {
    try ctx.requireValidUser();
    if (ctx.request.data.post) |pd| {
        std.debug.print("{any}\n", .{pd.items});
        return Repo.create(ctx);
    }
    return default(ctx);
}

fn default(ctx: *Frame) Error!void {
    try ctx.requireValidUser();

    var page = AdminPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{ .nav_buttons = &.{} } },
        .active_admin = .default,
        .admin_settings = null,
        .admin_remotes = null,
        .admin_repo_create = null,
        .admin_repo_delete = null,
        .admin_repo_clone = null,
    });
    try ctx.sendPage(&page);
}

const SettingsReq = struct {
    block_name: []const []const u8,
    block_text: []const []const u8,
};

fn settingsPost(vrs: *Frame) Router.Error!void {
    try vrs.requireValidUser();
    var post = vrs.request.data.post orelse return error.DataMissing;
    const settings_req = post.validateAlloc(SettingsReq, vrs.alloc) catch return error.DataInvalid;

    for (settings_req.block_name, settings_req.block_text) |name, text| {
        std.debug.print("block data:\nname '{s}'\ntext '''{s}'''\n", .{ name, text });
    }

    return vrs.redirect("/admin/settings", .see_other) catch unreachable;
}

pub fn settings(vrs: *Frame) Router.Error!void {
    try vrs.requireValidUser();
    var blocks: []S.ConfigBlocks = try vrs.alloc.alloc(S.ConfigBlocks, global_config.ctx.ns.len);
    for (global_config.ctx.ns, blocks) |ns, *block| {
        block.* = .{
            .config_name = ns.name,
            .config_text = ns.block,
            .count = mem.count(u8, ns.block, "\n") + 2,
        };
    }

    var page = AdminPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = vrs.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{ .nav_buttons = &.{} } },
        .active_admin = .settings,
        .admin_settings = .{ .config_blocks = blocks[0..] },
        .admin_remotes = null,
        .admin_repo_create = null,
        .admin_repo_delete = null,
        .admin_repo_clone = null,
    });

    try vrs.sendPage(&page);
}

fn remotes(ctx: *Frame) Error!void {
    try ctx.requireValidUser();

    var page = AdminPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{ .nav_buttons = &.{} } },
        .active_admin = .remotes,
        .admin_settings = null,
        .admin_remotes = null,
        .admin_repo_create = null,
        .admin_repo_delete = null,
        .admin_repo_clone = null,
    });
    try ctx.sendPage(&page);
}

const Repo = struct {
    pub const verse_name = .repo;
    pub const verse_routes = [_]Route.Match{
        Route.GET("clone", clone),
        Route.GET("create", create),
        Route.GET("delete", delete),
        Route.POST("clone", clonePost),
        Route.POST("create", createPost),
        Route.POST("delete", deletePost),
    };

    fn gitCreateRepo(a: Allocator, reponame: []const u8) !void {
        var dn_buf: [2048]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dn_buf, "repos/{}", .{reponame});
        var agent = git.Agent{ .alloc = a, .cwd = null };
        _ = try agent.gitInit(dir, .{});
    }

    const CreateRepoReq = struct {
        repo_name: []const u8,
    };

    fn createPost(ctx: *Frame) Error!void {
        try ctx.requireValidUser();
        var post = ctx.request.data.post orelse return error.DataMissing;
        const repo_req = post.validate(CreateRepoReq) catch return error.DataInvalid;

        if (repo_req.repo_name.len > 40) return error.DataInvalid;
        for (repo_req.repo_name) |c| {
            if (std.ascii.isAlphanumeric(c)) continue;
            if (c == '-' or c == '_') continue;
            return error.Abuse;
        }

        std.debug.print("creating {s}\n", .{repo_req.repo_name});
        var buf: [2048]u8 = undefined;
        const dir_name = try std.fmt.bufPrint(&buf, "repos/{s}", .{repo_req.repo_name});

        if (std.fs.cwd().openDir(dir_name, .{})) |_| return error.Unknown else |_| {}

        //const new_repo = git.Repo.createNew(ctx.alloc, std.fs.cwd(), dir_name) catch return error.Unknown;
        //std.debug.print("creating {any}\n", .{new_repo});

        const redirect_uri = try std.fmt.bufPrint(&buf, "/repo/{s}", .{repo_req.repo_name});
        return ctx.redirect(redirect_uri, .see_other) catch unreachable;
    }

    fn create(ctx: *Frame) Error!void {
        try ctx.requireValidUser();

        var page = AdminPage.init(.{
            .meta_head = .{ .open_graph = .{} },
            .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{ .nav_buttons = &.{} } },
            .active_admin = .repo_create,
            .admin_settings = null,
            .admin_remotes = null,
            .admin_repo_create = .{},
            .admin_repo_delete = null,
            .admin_repo_clone = null,
        });
        try ctx.sendPage(&page);
    }

    const deletePost = delete;

    fn delete(ctx: *Frame) Error!void {
        try ctx.requireValidUser();
        var page = AdminPage.init(.{
            .meta_head = .{ .open_graph = .{} },
            .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{ .nav_buttons = &.{} } },
            .active_admin = .repo_delete,
            .admin_settings = null,
            .admin_remotes = null,
            .admin_repo_create = null,
            .admin_repo_delete = .{},
            .admin_repo_clone = null,
        });
        try ctx.sendPage(&page);
    }

    const CloneUpstreamReq = struct {
        repo_uri: []const u8,
    };

    fn clonePost(ctx: *Frame) Error!void {
        try ctx.requireValidUser();

        var page = AdminPage.init(.{
            .meta_head = .{ .open_graph = .{} },
            .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{ .nav_buttons = &.{} } },
            .active_admin = .repo_clone,
            .admin_settings = null,
            .admin_remotes = null,
            .admin_repo_create = null,
            .admin_repo_delete = null,
            .admin_repo_clone = null,
        });

        var post = ctx.request.data.post orelse return error.DataMissing;
        const clone_req = post.validate(CloneUpstreamReq) catch return error.DataInvalid;

        std.debug.print("repo uri {s}\n", .{clone_req.repo_uri});
        var nameitr = std.mem.splitBackwardsScalar(u8, clone_req.repo_uri, '/');
        const new_repo_name = nameitr.first();
        std.debug.print("repo uri {s}\n", .{new_repo_name});
        // TODO sanitize requested repo name
        const dir = std.fs.cwd().openDir("repos", .{}) catch |err| {
            page.data.admin_repo_clone = .{ .post_error = .{ .err_str = @errorName(err) } };
            return try ctx.sendPage(&page);
        };

        var agent = git.Agent{ .alloc = ctx.alloc, .cwd = dir };
        std.debug.print("fork bare {s}\n", .{
            agent.forkRemote(clone_req.repo_uri, new_repo_name) catch |err| {
                page.data.admin_repo_clone = .{ .post_error = .{ .err_str = @errorName(err) } };
                return try ctx.sendPage(&page);
            },
        });

        // TODO redirect to new repo
        var buf: [2048]u8 = undefined;
        const redirect_uri = try std.fmt.bufPrint(&buf, "/repo/{s}", .{new_repo_name});
        return ctx.redirect(redirect_uri, .see_other) catch unreachable;
    }

    fn clone(ctx: *Frame) Error!void {
        try ctx.requireValidUser();
        var page = AdminPage.init(.{
            .meta_head = .{ .open_graph = .{} },
            .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{ .nav_buttons = &.{} } },
            .active_admin = .repo_clone,
            .admin_settings = null,
            .admin_remotes = null,
            .admin_repo_create = null,
            .admin_repo_delete = null,
            .admin_repo_clone = .{ .post_error = null },
        });
        try ctx.sendPage(&page);
    }
};

const git = @import("../git.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const mem = std.mem;
const verse = @import("verse");
const Frame = verse.Frame;
const Route = verse.Router;
const template = verse.template;
const S = template.Structs;
const HTML = template.html;
const DOM = HTML.DOM;
const Error = Route.Error;
const Router = verse.Router;
const RequestData = verse.RequestData.RequestData;
const global_config = &@import("../main.zig").global_config;
