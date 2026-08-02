pub const endpoints = [_]Router.Match{
    Router.ALL("", gitHttp),
    Router.ALL("objects", gitHttp),
    Router.ROUTE("info", &[_]Router.Match{
        Router.ALL("", gitHttp),
        Router.ALL("refs", gitHttp),
    }),
    Router.ALL("git-upload-pack", uploadPack),
    Router.ANY("git-receive-pack", receivePack),
};

pub fn router(f: *Frame) Router.RoutingError!Router.BuildFn {
    _ = f.uri.next(); // repo
    _ = f.uri.next(); // name
    // target
    log.warn("gitweb router {any} {s}", .{ f.request.method, f.uri.peek().? });
    return gitHttp;
}

// TODO
// https://git-scm.com/docs/git-config#Documentation/git-config.txt-receivemaxInputSize
// https://git-scm.com/docs/git-config#Documentation/git-config.txt-receivedenyDeletes

fn gitHttp(f: *Frame) Error!void {
    const qstr = f.request.data.query.bytes;
    const uri = f.uri.next() orelse &.{};
    log.warn("uri {s}", .{uri});
    if (eql(u8, qstr, "service=git-receive-pack") or eql(u8, uri, "git-receive-pack"))
        return receivePack(f);

    if (eql(u8, qstr, "service=git-upload-pack") or eql(u8, uri, "git-upload-pack"))
        return uploadPack(f);

    return error.ServerFault;
}

fn prepareEnv(f: *const Frame) !std.process.Environ.Map {
    const rd = RouteData.init(f.uri) orelse return error.ServerFault;
    const method = @tagName(f.request.method);
    const datadir = try types.currentPathAlloc(f.alloc, f.io);
    errdefer f.alloc.free(datadir);
    const username = if (f.user) |usr|
        usr.username orelse "anon"
    else
        "anon";

    var uri = f.uri;
    uri.reset();
    _ = uri.next() orelse return error.InvalidURI;
    _ = uri.next() orelse return error.InvalidURI;
    const path_tr = try allocPrint(f.alloc, "repos/{s}/{s}", .{ rd.name, uri.rest() });
    errdefer f.alloc.free(path_tr);
    log.warn("pathtr {s}", .{path_tr});

    var map = std.process.Environ.Map.init(f.alloc);
    try map.array_hash_map.ensureTotalCapacity(f.alloc, 32);
    errdefer map.deinit();

    // git env
    try map.put("GIT_HTTP_EXPORT_ALL", "true");
    try map.put("PATH_TRANSLATED", path_tr);
    try map.put("REMOTE_ADDR", f.request.remote_addr);
    try map.put("REQUEST_METHOD", method);
    try map.put("QUERY_STRING", "");
    try map.put("REMOTE_USER", username);

    switch (f.downstream.gateway) {
        .zwsgi => |z| for (z.vars.items) |vars| {
            if (eql(u8, vars.key, "HTTP_GIT_PROTOCOL")) {
                std.debug.assert(eql(u8, vars.val, "version=2"));
                try map.put("GIT_PROTOCOL", "version=2");
            }
        },
        else => @panic("not implemented"),
    }

    const qstr = f.request.data.query.bytes;
    if (startsWith(u8, qstr, "service=git-")) {
        if (eql(u8, qstr, "service=git-upload-pack")) {
            try map.put("QUERY_STRING", "service=git-upload-pack");
        } else if (eql(u8, qstr, "service=git-receive-pack")) {
            try map.put("QUERY_STRING", "service=git-receive-pack");
        } else log.warn("query string '{s}'", .{qstr});
    } else log.warn("query string '{s}'", .{qstr});

    try map.put("CONTENT_TYPE", if (f.request.headers.getCustom("HTTP_CONTENT_TYPE")) |ct|
        ct.list.items[0]
    else
        "");

    // srctree env
    try map.put("SRCTREE_DIRECT_ENABLED", "true");
    try map.put("SRCTREE_DIRECT_DATADIR", datadir);
    try map.put("SRCTREE_HTTP", "true");
    try map.put("SRCTREE_HOST", try (f.request.host orelse return error.DataMissing).valid());
    try map.put("SRCTREE_REPO", rd.name);

    if (f.user) |usr| {
        if (usr.username) |name| {
            try map.put("SRCTREE_USER", name);
        }
    }

    return map;
}

fn gzipEncoded(f: *const Frame) bool {
    switch (f.downstream.gateway) {
        .zwsgi => |z| for (z.vars.items) |vars| {
            log.debug("each {s} {s}", .{ vars.key, vars.val });
            if (eql(u8, vars.key, "HTTP_CONTENT_ENCODING")) {
                if (eql(u8, vars.val, "gzip"))
                    return true;
                log.err("unexpected encoding", .{});
                return false;
            }
        },
        else => @panic("not implemented"),
    }
    return false;
}

const default_hooks_path = "./bin/hooks";

fn spawn(f: *const Frame) !std.process.Child {
    var map = try prepareEnv(f);
    defer map.deinit();

    const core_path = "core.hooksPath={s}";

    var realpath_b: [2048]u8 = undefined;
    const dir = std.Io.Dir.cwd().openDir(f.io, ".", .{}) catch std.Io.Dir.cwd();
    defer dir.close(f.io);
    const len = dir.realPathFile(f.io, default_hooks_path, &realpath_b) catch |err| b: {
        log.err("core hooks path {}", .{err});
        break :b 0;
    };

    var b: [2048]u8 = undefined;
    const config = try print(&b, core_path, .{
        if (len > 0) realpath_b[0..len] else default_hooks_path,
    });
    log.info("path '{s}'", .{config});

    const argv: []const []const u8 = if ((Config.global.git orelse Config.Git.default).hooks_disabled) b: {
        log.warn("hooks bypassed", .{});
        break :b &.{ "git", "http-backend" };
    } else &.{ "git", "-c", config, "http-backend" };

    return std.process.spawn(f.io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = &map,
    }) catch |err| {
        log.err("Unable to spawn for gitweb {}", .{err});
        return error.ServerFault;
    };
}

fn receivePack(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.ServerFault;
    if (!rd.exists(.all, f.io)) {
        if (f.user) |_| return try receivePackInternal(f);
        return error.ServerFault;
    }
    return try receivePackExternal(f);
}

fn autoCreateSkel(f: *Frame) Error!void {
    f.downstream.writer.interface.writeAll("HTTP/1.1 200 OK\r\n" ++
        "Expires: Fri, 01 Jan 1980 00:00:00 GMT\r\n" ++
        "Pragma: no-cache\r\n" ++
        "Cache-Control: no-cache, max-age=0, must-revalidate\r\n" ++
        "Content-Type: application/x-git-receive-pack-advertisement\r\n" ++
        "\r\n") catch
        return log.err("unable to start headers for fake repo", .{});

    try git.protocol.announceFake(.receive, &f.downstream.writer.interface);
}

fn receivePackInternal(f: *Frame) Error!void {
    return try autoCreateSkel(f);
}

fn receivePackExternal(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.ServerFault;
    const gz_encoded = gzipEncoded(f);

    if (f.user == null) {
        // TODO visibility
        var repo = (Repo.openGit(rd.name, .public_only, f.io) catch
            return error.ServerFault) orelse
            return error.InvalidURI;
        repo.loadConfig(f.alloc, f.io) catch return error.ServerFault;
        if (repo.config.?.srctree) |cfg| {
            if (cfg.anonpushenabled) |enabled| {
                if (!enabled) return error.Unauthorized;
            } else return error.Unauthorized;
        } else return error.Unauthorized;
    }

    var child = try spawn(f);
    const stdin = child.stdin orelse return error.ServerFault;
    if (f.request.data.post) |pd| {
        var post_bytes: Reader = .fixed(pd.bytes);
        var gz_b: [std.compress.flate.max_window_len]u8 = undefined;
        var gzip: std.compress.flate.Decompress = .init(&post_bytes, .gzip, &gz_b);
        const reader: *Reader = if (gz_encoded) &gzip.reader else &post_bytes;

        var w_b: [6400]u8 = undefined; // This is what I saw while debugging
        var stdin_w = stdin.writer(f.io, &w_b);
        _ = reader.streamRemaining(&stdin_w.interface) catch unreachable;
        try stdin_w.interface.flush();
    }
    child.stdin = null;
    stdin.close(f.io);

    const stdout = child.stdout orelse return error.ServerFault;
    var r_b: [6400]u8 = undefined; // This is the size seen during debugging
    var stdout_r = stdout.reader(f.io, &r_b);

    const stderr = child.stderr orelse @panic("oops");
    var err_b: [6400]u8 = undefined; // This is what I saw while debugging
    var stderr_r = stderr.reader(f.io, &err_b);

    log.err("'''", .{});
    log.err("'''", .{});
    log.err("'''", .{});
    log.err("'''", .{});
    log.err("'''", .{});
    log.err("'''", .{});
    log.err("'''", .{});
    // we just guess and assume it'll return 200 checking would be better
    f.downstream.writer.interface.writeAll("HTTP/1.1 200 OK\r\n") catch
        return debugStderr("unable to start headers", &child, f.io);

    var w: std.Io.Writer.Allocating = try .initCapacity(f.alloc, 64000);

    _ = stderr_r.interface.streamRemaining(&w.writer) catch
        return debugStderr("unable to stream body", &child, f.io);
    _ = stdout_r.interface.streamRemaining(&w.writer) catch
        return debugStderr("unable to stream body", &child, f.io);

    _ = f.downstream.writer.interface.writeAll(w.writer.buffered()) catch
        return debugStderr("unable to stream body", &child, f.io);

    stdout_r.interface.fillMore() catch {};
    log.err("'''\n{s}\n'''", .{w.writer.buffered()});

    //defer {
    stderr_r.interface.fillMore() catch {};
    log.err("'''\n{s}\n'''", .{stderr_r.interface.buffered()});
    //}

    if (child.wait(f.io)) |chld| {
        log.err("child {}", .{chld});
        if (chld.exited != 0) return debugStderr("unable to stream body", &child, f.io);
    } else |err| {
        log.err("Error waiting for child {}", .{err});
        return error.ServerFault;
    }
    f.downstream.writer.interface.flush() catch log.err("final flush failed", .{});
}

fn uploadPack(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.ServerFault;
    if (!rd.exists(.all, f.io) and f.user != null) {
        return try uploadPackInternal(f);
    }
    return try uploadPackExternal(f);
}

const uploadPackInternal = uploadPackExternal;

fn uploadPackExternal(f: *Frame) Error!void {
    const gz_encoded = gzipEncoded(f);
    var child = try spawn(f);
    if (f.request.data.post) |pd| {
        const stdin = child.stdin orelse return error.ServerFault;
        var post_bytes: Reader = .fixed(pd.bytes);
        var gz_b: [std.compress.flate.max_window_len]u8 = undefined;
        var gzip: std.compress.flate.Decompress = .init(&post_bytes, .gzip, &gz_b);
        const reader: *Reader = if (gz_encoded) &gzip.reader else &post_bytes;

        var w_b: [6400]u8 = undefined; // This is what I saw while debugging
        var stdin_w = stdin.writer(f.io, &w_b);
        _ = reader.streamRemaining(&stdin_w.interface) catch unreachable;
        try stdin_w.interface.flush();
    }
    if (child.stdin) |stdin| stdin.close(f.io);
    child.stdin = null;

    const stdout = child.stdout orelse return error.ServerFault;
    var r_b: [6400]u8 = undefined; // This is what I saw while debugging
    var stdout_r = stdout.reader(f.io, &r_b);

    // we just guess and assume it'll return 200 checking would be better
    f.downstream.writer.interface.writeAll("HTTP/1.1 200 OK\r\n") catch
        return debugStderr("unable to start headers", &child, f.io);

    _ = stdout_r.interface.streamRemaining(&f.downstream.writer.interface) catch
        return debugStderr("unable to stream body", &child, f.io);

    if (child.wait(f.io)) |chld| {
        log.info("child {}", .{chld});
        if (chld.exited != 0) {
            return debugStderr("unable to stream body", &child, f.io);
        }
    } else |err| {
        log.err("Error waiting for child {}", .{err});
        return error.ServerFault;
    }
    f.downstream.writer.interface.flush() catch log.err("final flush failed", .{});
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
    //_ = child.wait(io) catch {};
    return error.ServerFault;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const POLL = std.posix.POLL;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const log = std.log.scoped(.gitweb);
const allocPrint = std.fmt.allocPrint;
const print = std.fmt.bufPrint;
const RouteData = @import("endpoints/repos.zig").RouteData;

const main = @import("main.zig");
const types = @import("types.zig");

const verse = @import("verse");
const Frame = verse.Frame;
const Request = verse.Request;
const Router = verse.Router;
const Error = Router.Error;

const git = @import("git.zig");
const repos = @import("repos.zig");
const Repo = @import("Repo.zig");
const Config = @import("Config.zig");
