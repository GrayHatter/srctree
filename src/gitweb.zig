pub const endpoints = [_]Router.Match{
    Router.ANY("objects", gitUploadPack),
    Router.ROUTE("info", &[_]Router.Match{
        Router.ANY("", gitUploadPack),
        Router.ANY("refs", gitUploadPack),
    }),
    Router.ANY("git-upload-pack", gitUploadPack),
};

pub fn router(ctx: *Verse.Frame) Router.RoutingError!Router.BuildFn {
    std.debug.print("gitweb router {s}\n{any}, {any} \n", .{ ctx.ctx.uri.peek().?, ctx.ctx.uri, ctx.request.method });
    return Router.router(ctx, &endpoints);
}

fn gitUploadPack(ctx: *Verse.Frame) Error!void {
    ctx.uri.reset();
    _ = ctx.uri.first();
    const name = ctx.uri.next() orelse return error.Unknown;
    const target = ctx.uri.rest();
    if (!eql(u8, target, "info/refs") and !eql(u8, target, "git-upload-pack")) {
        return error.Abuse;
    }

    var path_buf: [2048]u8 = undefined;
    const path_tr = std.fmt.bufPrint(&path_buf, "repos/{s}/{s}", .{ name, target }) catch unreachable;
    std.debug.print("pathtr {s}\n", .{path_tr});

    var map = std.process.EnvMap.init(ctx.alloc);
    defer map.deinit();
    var gz_encoding = false;
    //(if GIT_PROJECT_ROOT is set, otherwise PATH_TRANSLATED)
    if (ctx.request.method == .GET) {
        try map.put("PATH_TRANSLATED", path_tr);
        try map.put("QUERY_STRING", "service=git-upload-pack");
        try map.put("REQUEST_METHOD", "GET");
    } else {
        try map.put("PATH_TRANSLATED", path_tr);
        try map.put("QUERY_STRING", "");
        try map.put("REQUEST_METHOD", "POST");
    }
    try map.put("REMOTE_USER", "");
    try map.put("REMOTE_ADDR", ctx.request.remote_addr);
    try map.put("CONTENT_TYPE", "application/x-git-upload-pack-request");
    try map.put("GIT_PROTOCOL", "version=2");
    try map.put("GIT_HTTP_EXPORT_ALL", "true");

    switch (ctx.downstream.gateway) {
        .zwsgi => |z| {
            for (z.vars.items) |vars| {
                std.debug.print("each {s} {s} \n", .{ vars.key, vars.val });
                if (eql(u8, vars.key, "HTTP_CONTENT_ENCODING")) {
                    if (eql(u8, vars.val, "gzip")) {
                        gz_encoding = true;
                    } else {
                        std.debug.print("unexpected encoding\n", .{});
                    }
                }
            }
        },
        else => @panic("not implemented"),
    }

    var child = std.process.Child.init(&[_][]const u8{ "git", "http-backend" }, ctx.alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    //child.stderr_behavior = .Pipe;
    child.env_map = &map;
    child.expand_arg0 = .no_expand;

    ctx.status = .ok;

    child.spawn() catch unreachable;

    const err_mask = POLL.ERR | POLL.NVAL | POLL.HUP;
    var poll_fd = [_]std.posix.pollfd{
        .{ .fd = child.stdout.?.handle, .events = POLL.IN, .revents = undefined },
    };

    const post_data: ?[]const u8 = if (ctx.request.data.post) |pd| pd.rawpost else null;
    if (post_data) |pd| {
        var w_b: [6400]u8 = undefined; // This is what I saw while debugging
        var writer = child.stdin.?.writer(&w_b);
        defer child.stdin = null;
        defer child.stdin.?.close();
        defer writer.interface.flush() catch unreachable;

        if (gz_encoding) {
            var post_reader: Reader = .fixed(pd);
            var gz_b: [std.compress.flate.max_window_len]u8 = undefined;
            var gzip: std.compress.flate.Decompress = .init(&post_reader, .gzip, &gz_b);
            _ = gzip.reader.streamRemaining(&writer.interface) catch unreachable;
        } else {
            writer.interface.writeAll(pd) catch unreachable;
        }
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
                _ = ctx.downstream.writer.writeAll("HTTP/1.1 200 OK\r\n") catch unreachable;
                headers_required = false;
            }
            ctx.downstream.writer.writeAll(buf[0..amt]) catch unreachable;
        } else if (poll_fd[0].revents & err_mask != 0) {
            break;
        }
    }

    if (child.stderr) |stderr| {
        var stderr_buf = try ctx.alloc.alloc(u8, 0xffffff);
        const stderr_read = std.posix.read(stderr.handle, stderr_buf) catch unreachable;
        std.debug.print("stderr\n{s}\n", .{stderr_buf[0..stderr_read]});
    }
    _ = child.wait() catch unreachable;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const POLL = std.posix.POLL;
const eql = std.mem.eql;

const Verse = @import("verse");
const Request = Verse.Request;
const Router = Verse.Router;
const Error = Router.Error;

const git = @import("git.zig");
