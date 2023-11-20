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
    .{ .name = "objects", .match = .{ .call = objects } },
    .{ .name = "info", .match = .{ .simple = &[_]Endpoint.Router.MatchRouter{
        .{ .name = "", .match = .{ .call = info } },
        .{ .name = "refs", .match = .{ .call = info } },
    } } },

    .{ .name = "git-upload-pack", .methods = POST, .match = .{ .call = gitUploadPack } },
};

pub fn router(ctx: *Context) Error!Endpoint.Endpoint {
    std.debug.print("gitweb router {s}\n{any}, {any} \n", .{ ctx.uri.peek().?, ctx.uri, ctx.request.method });
    return Endpoint.Router.router(ctx, &endpoints);
}

fn gitUploadPack(r: *Response, uri: *UriIter) Error!void {
    _ = uri;

    std.debug.print("upload-pack", .{});
    var map = std.process.EnvMap.init(r.alloc);

    var child = std.ChildProcess.init(&[_][]const u8{ "git", "http-backend" }, r.alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = &map;
    child.expand_arg0 = .no_expand;
}

fn objects(r: *Response, uri: *UriIter) Error!void {
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

fn info(r: *Response, uri: *UriIter) Error!void {
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
