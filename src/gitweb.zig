const std = @import("std");

const Allocator = std.mem.Allocator;

const Context = @import("context.zig");
const Response = @import("response.zig");
const Request = @import("request.zig");
const HTML = @import("html.zig");
const elm = HTML.element;
const DOM = @import("dom.zig");
const Template = @import("template.zig");

const Route = @import("routes.zig");
const Error = Route.Error;
const UriIter = Route.UriIter;

const POLL = std.posix.POLL;

const git = @import("git.zig");
const Ini = @import("ini.zig");
const Humanize = @import("humanize.zig");
const Bleach = @import("bleach.zig");

pub const endpoints = [_]Route.Match{
    .{ .name = "objects", .match = .{ .call = gitUploadPack } },
    .{ .name = "info", .match = .{ .simple = &[_]Route.Match{
        .{ .name = "", .match = .{ .call = gitUploadPack } },
        .{ .name = "refs", .match = .{ .call = gitUploadPack } },
    } } },

    .{ .name = "git-upload-pack", .methods = .{ .POST = true }, .match = .{ .call = gitUploadPack } },
};

pub fn router(ctx: *Context) Error!Route.Callable {
    std.debug.print("gitweb router {s}\n{any}, {any} \n", .{ ctx.ctx.uri.peek().?, ctx.ctx.uri, ctx.request.method });
    return Route.router(ctx, &endpoints);
}

fn gitUploadPack(ctx: *Context) Error!void {
    ctx.uri.reset();
    _ = ctx.uri.first();
    const name = ctx.uri.next() orelse return error.Unknown;
    const target = ctx.uri.rest();
    if (!std.mem.eql(u8, target, "info/refs") and !std.mem.eql(u8, target, "git-upload-pack")) {
        return error.Abusive;
    }

    var path_buf: [2048]u8 = undefined;
    const path_tr = std.fmt.bufPrint(&path_buf, "repos/{s}/{s}", .{ name, target }) catch unreachable;
    std.debug.print("pathtr {s}\n", .{path_tr});

    var map = std.process.EnvMap.init(ctx.alloc);
    defer map.deinit();

    //(if GIT_PROJECT_ROOT is set, otherwise PATH_TRANSLATED)
    if (ctx.req_data.post_data == null) {
        try map.put("PATH_TRANSLATED", path_tr);
        try map.put("QUERY_STRING", "service=git-upload-pack");
        try map.put("REQUEST_METHOD", "GET");
    } else {
        try map.put("PATH_TRANSLATED", path_tr);
        try map.put("QUERY_STRING", "");
        try map.put("REQUEST_METHOD", "POST");
    }
    try map.put("REMOTE_USER", "");
    try map.put("REMOTE_ADDR", "");
    try map.put("CONTENT_TYPE", "application/x-git-upload-pack-request");
    try map.put("GIT_PROTOCOL", "version=2");
    try map.put("GIT_HTTP_EXPORT_ALL", "true");

    var child = std.ChildProcess.init(&[_][]const u8{ "git", "http-backend" }, ctx.alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.env_map = &map;
    child.expand_arg0 = .no_expand;

    ctx.response.status = .ok;

    child.spawn() catch unreachable;

    const err_mask = POLL.ERR | POLL.NVAL | POLL.HUP;
    var poll_fd = [_]std.posix.pollfd{
        .{
            .fd = child.stdout.?.handle,
            .events = POLL.IN,
            .revents = undefined,
        },
    };
    if (ctx.req_data.post_data) |pd| {
        _ = std.posix.write(child.stdin.?.handle, pd.rawpost) catch unreachable;
        std.posix.close(child.stdin.?.handle);
        child.stdin = null;
    }
    var buf = try ctx.alloc.alloc(u8, 0xffffff);
    var headers_required = true;
    while (true) {
        const events_len = std.posix.poll(&poll_fd, std.math.maxInt(i32)) catch unreachable;
        if (events_len == 0) continue;
        if (poll_fd[0].revents & POLL.IN != 0) {
            const amt = std.posix.read(poll_fd[0].fd, buf) catch unreachable;
            if (amt == 0) break;
            if (headers_required) {
                _ = ctx.response.write("HTTP/1.1 200 OK\r\n") catch unreachable;
                headers_required = false;
            }
            ctx.response.writeAll(buf[0..amt]) catch unreachable;
        } else if (poll_fd[0].revents & err_mask != 0) {
            break;
        }
    }
    _ = child.wait() catch unreachable;
}

fn __objects(ctx: *Context) Error!void {
    std.debug.print("gitweb objects\n", .{});

    const rd = @import("../../REPO.RouteData.make(ctx.uri) orelse return error.Unrouteable.zig");

    var cwd = std.fs.cwd();
    var filename = try std.fmt.allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    const dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;

    ctx.uri.reset();
    _ = ctx.uri.first();
    _ = ctx.uri.next();
    _ = ctx.uri.next();
    const o2 = ctx.uri.next().?;
    const o38 = ctx.uri.next().?;

    filename = try std.fmt.allocPrint(ctx.alloc, "./repos/{s}/objects/{s}/{s}", .{ rd.name, o2, o38 });
    var file = cwd.openFile(filename, .{}) catch unreachable;
    const data = file.readToEndAlloc(ctx.alloc, 0xffffff) catch unreachable;

    //var sha: [40]u8 = undefined;
    //@memcpy(sha[0..2], o2[0..2]);
    //@memcpy(sha[2..40], o38[0..38]);

    //var data = repo.findBlob(ctx.alloc, &sha) catch unreachable;

    ctx.response.status = .ok;
    ctx.response.start() catch return Error.Unknown;
    ctx.response.write(data) catch return Error.Unknown;
    ctx.response.finish() catch return Error.Unknown;
}

fn __info(ctx: *Context) Error!void {
    std.debug.print("gitweb info\n", .{});

    const rd = @import("../../REPO.RouteData.make(ctx.uri) orelse return error.Unrouteable.zig");

    var cwd = std.fs.cwd();
    const filename = try std.fmt.allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    const dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;

    var adata = std.ArrayList(u8).init(ctx.alloc);

    for (repo.refs) |ref| {
        std.debug.print("{}\n", .{ref});
        switch (ref) {
            .branch => |b| {
                std.debug.print("{s}\n", .{b.name});
                try adata.appendSlice(b.sha);
                try adata.appendSlice("\t");
                try adata.appendSlice("refs/heads/");
                try adata.appendSlice(b.name);
                try adata.appendSlice("\n");
            },
            else => std.debug.print("else\n", .{}),
        }
    }

    const data = try adata.toOwnedSlice();

    ctx.response.status = .ok;
    ctx.response.start() catch return Error.Unknown;
    ctx.response.write(data) catch return Error.Unknown;
    ctx.response.finish() catch return Error.Unknown;
}
