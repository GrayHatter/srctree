pub const endpoints = [_]Router.Match{
    Router.ANY("objects", gitUploadPack),
    Router.ROUTE("info", &[_]Router.Match{
        Router.ANY("", gitUploadPack),
        Router.ANY("refs", gitUploadPack),
    }),
    Router.ANY("git-upload-pack", gitUploadPack),
};

pub fn router(ctx: *Frame) Router.RoutingError!Router.BuildFn {
    std.debug.print("gitweb router {s}\n{any}, {any} \n", .{ ctx.ctx.uri.peek().?, ctx.ctx.uri, ctx.request.method });
    return Router.router(ctx, &endpoints);
}

fn gitUploadPack(f: *Frame) Error!void {
    f.uri.reset();
    _ = f.uri.first();
    const name = f.uri.next() orelse return error.Unknown;
    const target = f.uri.rest();
    if (!eql(u8, target, "info/refs") and !eql(u8, target, "git-upload-pack")) {
        return error.Abuse;
    }

    var path_buf: [2048]u8 = undefined;
    const path_tr = std.fmt.bufPrint(&path_buf, "repos/{s}/{s}", .{ name, target }) catch unreachable;
    log.warn("pathtr {s}", .{path_tr});

    var map = std.process.Environ.Map.init(f.alloc);
    defer map.deinit();
    try map.put("PATH_TRANSLATED", path_tr);
    var gz_encoding = false;
    //(if GIT_PROJECT_ROOT is set, otherwise PATH_TRANSLATED)
    if (f.request.method == .GET) {
        try map.put("REQUEST_METHOD", "GET");
    } else {
        try map.put("REQUEST_METHOD", "POST");
    }
    const qstr = f.request.data.query.bytes;
    if (eql(u8, qstr, "service=git-upload-pack")) {
        try map.put("QUERY_STRING", "service=git-upload-pack");
    } else {
        log.warn("query string '{s}'", .{qstr});
        try map.put("QUERY_STRING", "");
    }

    try map.put("REMOTE_USER", "");
    try map.put("REMOTE_ADDR", f.request.remote_addr);
    try map.put("CONTENT_TYPE", "application/x-git-upload-pack-request");
    try map.put("GIT_PROTOCOL", "version=2");
    try map.put("GIT_HTTP_EXPORT_ALL", "true");

    switch (f.downstream.gateway) {
        .zwsgi => |z| {
            for (z.vars.items) |vars| {
                log.info("each {s} {s}", .{ vars.key, vars.val });
                if (eql(u8, vars.key, "HTTP_CONTENT_ENCODING")) {
                    if (eql(u8, vars.val, "gzip")) {
                        gz_encoding = true;
                    } else {
                        log.err("unexpected encoding", .{});
                    }
                }
            }
        },
        else => @panic("not implemented"),
    }

    var child = std.process.spawn(f.io, .{
        .argv = &.{ "git", "http-backend" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = &map,
    }) catch |err| {
        log.err("Unable to spawn for gitweb {}", .{err});
        return error.ServerFault;
    };

    if (f.request.data.post) |pd| {
        const stdin = child.stdin orelse return error.ServerFault;
        defer child.stdin = null;
        defer stdin.close(f.io);

        var w_b: [6400]u8 = undefined; // This is what I saw while debugging
        var stdin_w = stdin.writer(f.io, &w_b);
        if (gz_encoding) {
            var post_reader: Reader = .fixed(pd.bytes);
            var gz_b: [std.compress.flate.max_window_len]u8 = undefined;
            var gzip: std.compress.flate.Decompress = .init(&post_reader, .gzip, &gz_b);
            _ = gzip.reader.streamRemaining(&stdin_w.interface) catch |err| {
                log.err("gz stream error {}", .{err});
                return error.ServerFault;
            };
        } else {
            try stdin_w.interface.writeAll(pd.bytes);
        }
        try stdin_w.interface.flush();
    }

    const stdout = child.stdout orelse return error.ServerFault;
    var r_b: [6400]u8 = undefined; // This is what I saw while debugging
    var stdout_r = stdout.reader(f.io, &r_b);
    stdout_r.interface.fillMore() catch
        return debugStderr("unable to start headers", &child, f.io);

    if (stdout_r.interface.bufferedLen() > 0) {
        f.downstream.writer.writeAll("HTTP/1.1 200 OK\r\n") catch
            return debugStderr("unable to start headers", &child, f.io);
    }

    while (stdout_r.interface.stream(f.downstream.writer, .limited(0x800000))) |_| {
        //
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return debugStderr("unable to stream body", &child, f.io),
    }
    f.downstream.writer.flush() catch log.err("final flush failed", .{});

    if (child.wait(f.io)) |chld| {
        if (chld.exited != 0) {
            return debugStderr("unable to stream body", &child, f.io);
        } else {
            log.info("child {}", .{chld});
        }
    } else |err| {
        log.err("Error waiting for child {}", .{err});
        return error.ServerFault;
    }
}

fn debugStderr(comptime msg: []const u8, child: *std.process.Child, io: std.Io) !void {
    log.err(msg, .{});
    if (child.stderr) |stderr| {
        var b: [2048]u8 = undefined;
        var stderr_r = stderr.reader(io, &b);
        while (stderr_r.interface.takeDelimiter('\n') catch null) |line| {
            log.err("stderr {s}", .{line});
        }
    }
    _ = child.wait(io) catch unreachable;
    return error.ServerFault;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const POLL = std.posix.POLL;
const eql = std.mem.eql;
const log = std.log.scoped(.gitweb);

const verse = @import("verse");
const Frame = verse.Frame;
const Request = verse.Request;
const Router = verse.Router;
const Error = Router.Error;

const git = @import("git.zig");
