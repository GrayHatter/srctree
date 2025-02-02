const std = @import("std");
const eql = std.mem.eql;
const verse = @import("verse");
const Frame = verse.Frame;

const Router = verse.Router;
const template = verse.template;
const S = template.Structs;

const ROUTE = Router.ROUTE;
const GET = Router.GET;
const STATIC = Router.STATIC;
const Match = Router.Match;
const BuildFn = Router.BuildFn;

const commitFlex = @import("endpoints/commit-flex.zig").commitFlex;

pub const endpoints = verse.Endpoints(.{
    struct {
        pub const verse_name = .root;
        pub const verse_routes = [_]Match{
            GET("debug", debug),
            ROUTE("user", commitFlex),
            STATIC("static"),
            GET("robots.txt", robots),
        };
        pub const verse_builder = &builder;
        pub const index = commitFlex;
    },
    @import("api.zig"),
    @import("endpoints/admin.zig"),
    @import("endpoints/gist.zig"),
    @import("endpoints/network.zig"),
    @import("endpoints/repos.zig"),
    @import("endpoints/search.zig"),
    @import("endpoints/settings.zig"),
});

const E404Page = template.PageData("4XX.html");

fn robots(frame: *Frame) Router.Error!void {
    frame.status = .ok;
    frame.content_type = .{ .base = .{ .text = .plain } };
    frame.sendHeaders() catch |err| switch (err) {
        error.HeadersFinished => unreachable,
        inline else => |e| return e,
    };

    try frame.sendRawSlice("\r\n");
    try frame.sendRawSlice(
        \\User-agent: *
        \\Allow: /
        \\
    );
}

fn notFound(vrs: *Frame) Router.Error!void {
    std.debug.print("404 for route\n", .{});
    vrs.status = .not_found;
    var page = E404Page.init(.{});
    vrs.sendPage(&page) catch unreachable;
}

fn debug(_: *Frame) Router.Error!void {
    return error.Abusive;
}

fn builder(vrs: *Frame, call: BuildFn) void {
    const btns = [1]S.NavButtons{.{ .name = "inbox", .extra = 0, .url = "/inbox" }};
    var bh: S.BodyHeaderHtml = vrs.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{
        .nav_auth = "Error",
        .nav_buttons = &btns,
    } };

    bh.nav.nav_auth = if (vrs.user) |usr| n: {
        break :n if (usr.username) |un| un else "Error No Username";
    } else "Public";
    vrs.response_data.add(bh) catch {};
    return call(vrs) catch |err| switch (err) {
        error.InvalidURI => builder(vrs, notFound), // TODO catch inline
        error.BrokenPipe => std.debug.print("client disconnect", .{}),
        error.IOWriteFailure => @panic("Unexpected IOWrite"),
        error.Unrouteable => {
            std.debug.print("Unrouteable", .{});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
        },
        error.NotImplemented,
        error.Unknown,
        error.OutOfMemory,
        error.NoSpaceLeft,
        => {
            std.debug.print("Unexpected error '{}'", .{err});
            @panic("not implemented");
        },
        error.Abusive,
        error.Unauthenticated,
        error.BadData,
        error.DataMissing,
        => {
            std.debug.print("Abusive {} because {}\n", .{ vrs.request, err });
            for (vrs.request.raw.zwsgi.vars) |vars| {
                std.debug.print("Abusive var '{s}' => '''{s}'''\n", .{ vars.key, vars.val });
            }
            if (vrs.request.data.post) |post_data| {
                std.debug.print("post data => '''{s}'''\n", .{post_data.rawpost});
            }
        },
    };
}
