const std = @import("std");

const Allocator = std.mem.Allocator;

const Endpoint = @import("endpoint.zig");
const Context = @import("context.zig");
const Response = Endpoint.Response;
const Request = Endpoint.Request;
const HTML = Endpoint.HTML;
const elm = HTML.element;
const DOM = Endpoint.DOM;
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;

const git = @import("git.zig");
const Ini = @import("ini.zig");
const Humanize = @import("humanize.zig");
const Bleach = @import("bleach.zig");

const POST = Endpoint.Router.Methods.POST;

pub const endpoints = [_]Endpoint.Router.MatchRouter{
    .{ .name = "objects", .match = .{ .call = gitUploadPack } },
    .{ .name = "info", .match = .{ .simple = &[_]Endpoint.Router.MatchRouter{
        .{ .name = "", .match = .{ .call = gitUploadPack } },
        .{ .name = "refs", .match = .{ .call = gitUploadPack } },
    } } },

    .{ .name = "git-upload-pack", .methods = POST, .match = .{ .call = gitUploadPack } },
};

pub fn router(ctx: *Context) Error!Endpoint.Endpoint {
    std.debug.print("gitweb router {s}\n{any}, {any} \n", .{ ctx.uri.peek().?, ctx.uri, ctx.request.method });
    return Endpoint.Router.router(ctx, &endpoints);
}

fn gitUploadPack(r: *Response, uri: *UriIter) Error!void {
    uri.reset();
    _ = uri.first();
    const name = uri.next() orelse return error.Unknown;
    const target = uri.rest();
    if (!std.mem.eql(u8, target, "info/refs") and !std.mem.eql(u8, target, "git-upload-pack")) {
        return error.Abusive;
    }

    var path_buf: [2048]u8 = undefined;
    const path_tr = std.fmt.bufPrint(&path_buf, "repos/{s}/{s}", .{ name, target }) catch unreachable;
    std.debug.print("pathtr {s}\n", .{path_tr});

    var map = std.process.EnvMap.init(r.alloc);
    defer map.deinit();

    //(if GIT_PROJECT_ROOT is set, otherwise PATH_TRANSLATED)
    if (r.post_data == null) {
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

    var child = std.ChildProcess.init(&[_][]const u8{ "git", "http-backend" }, r.alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.env_map = &map;
    child.expand_arg0 = .no_expand;

    r.status = .ok;
    r.phase = .headers;

    child.spawn() catch unreachable;

    const err_mask = std.os.POLL.ERR | std.os.POLL.NVAL | std.os.POLL.HUP;
    var poll_fd = [_]std.os.pollfd{
        .{
            .fd = child.stdout.?.handle,
            .events = std.os.POLL.IN,
            .revents = undefined,
        },
    };
    if (r.post_data) |pd| {
        _ = std.os.write(child.stdin.?.handle, pd.rawdata) catch unreachable;
        std.os.close(child.stdin.?.handle);
        child.stdin = null;
    }
    var buf = try r.alloc.alloc(u8, 0xffffff);
    var headers_required = true;
    while (true) {
        const events_len = std.os.poll(&poll_fd, std.math.maxInt(i32)) catch unreachable;
        if (events_len == 0) continue;
        if (poll_fd[0].revents & std.os.POLL.IN != 0) {
            const amt = std.os.read(poll_fd[0].fd, buf) catch unreachable;
            if (amt == 0) break;
            if (headers_required) {
                _ = r.write("HTTP/1.1 200 OK\r\n") catch unreachable;
                headers_required = false;
            }
            r.writeAll(buf[0..amt]) catch unreachable;
        } else if (poll_fd[0].revents & err_mask != 0) {
            break;
        }
    }
    _ = child.wait() catch unreachable;
}

fn __objects(r: *Response, uri: *UriIter) Error!void {
    std.debug.print("gitweb objects\n", .{});

    const rd = Endpoint.REPO.RouteData.make(uri) orelse return error.Unrouteable;

    var cwd = std.fs.cwd();
    var filename = try std.fmt.allocPrint(r.alloc, "./repos/{s}", .{rd.name});
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(r.alloc) catch return error.Unknown;

    uri.reset();
    _ = uri.first();
    _ = uri.next();
    _ = uri.next();
    const o2 = uri.next().?;
    const o38 = uri.next().?;

    filename = try std.fmt.allocPrint(r.alloc, "./repos/{s}/objects/{s}/{s}", .{ rd.name, o2, o38 });
    var file = cwd.openFile(filename, .{}) catch unreachable;
    var data = file.readToEndAlloc(r.alloc, 0xffffff) catch unreachable;

    //var sha: [40]u8 = undefined;
    //@memcpy(sha[0..2], o2[0..2]);
    //@memcpy(sha[2..40], o38[0..38]);

    //var data = repo.findBlob(r.alloc, &sha) catch unreachable;

    r.status = .ok;
    r.start() catch return Error.Unknown;
    r.write(data) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}

fn __info(r: *Response, uri: *UriIter) Error!void {
    std.debug.print("gitweb info\n", .{});

    const rd = Endpoint.REPO.RouteData.make(uri) orelse return error.Unrouteable;

    var cwd = std.fs.cwd();
    var filename = try std.fmt.allocPrint(r.alloc, "./repos/{s}", .{rd.name});
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(r.alloc) catch return error.Unknown;

    var adata = std.ArrayList(u8).init(r.alloc);

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

    var data = try adata.toOwnedSlice();

    r.status = .ok;
    r.start() catch return Error.Unknown;
    r.write(data) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}