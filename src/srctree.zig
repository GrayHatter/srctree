const root = @This();

pub const verse_name = .root;
pub const verse_routes = [_]Match{
    verse.robotsTxt(&.{
        .{ .name = "GoogleOther", .allow = false }, // aggressive genai bot
        .{ .name = "SiteAuditBot", .allow = false }, // selfish bot
        .{ .name = "DataForSeoBot", .allow = false }, // selfish bot
        .{ .name = "Zoominfobot", .allow = false }, // selfish bot
        .{ .name = "BacklinksExtendedBot", .allow = false }, // selfish bot
        .{ .name = "barkrowler", .allow = false }, // selfish bot
        .{ .name = "ClaudeBot", .allow = false }, // aggressive, selfish
        .{
            .name = "ImagesiftBot",
            .allow = true,
            .extra =
            \\Disallow: /repo/*/commit/*
            \\Disallow: /repo/*/blame/*
            \\Disallow: /repo/*/blob/*
            \\
            ,
        },
        .{ .name = "AcademicBotRTU", .allow = false },
    }, .{ .extra_rules = "Disallow: /*?*\n" }),
    GET("debug", debug),
    ROUTE("user", commitFlex),
    STATIC("static"),
};
pub const verse_builder = &builder;
pub const index = commitFlex;

pub const endpoints = verse.Endpoints(.{
    root,
    verse.stats.Endpoint,
    @import("api.zig"),
    @import("endpoints/admin.zig"),
    @import("endpoints/gist.zig"),
    @import("endpoints/network.zig"),
    @import("endpoints/repos.zig"),
    @import("endpoints/search.zig"),
    @import("endpoints/settings.zig"),
    @import("endpoints/debugging.zig"),
});

const E404Page = template.PageData("4XX.html");

fn notFound(vrs: *Frame) Router.Error!void {
    std.debug.print("404 for route\n", .{});
    vrs.status = .not_found;
    var page = E404Page.init(.{});
    vrs.sendPage(&page) catch unreachable;
}

fn debug(_: *Frame) Router.Error!void {
    return error.Unrouteable;
}

fn builder(fr: *Frame, call: BuildFn) void {
    if (fr.request.user_agent) |ua| {
        if (ua.resolved == .bot and ua.resolved.bot.name == .googlebot or fr.user != null) {} else {
            fr.dumpDebugData(.{});
            ua.botDetectionDump(fr.request);
        }
    } else {
        std.debug.print("No User agent for request\n\n\n\n", .{});
        fr.dumpDebugData(.{});
    }

    const btns = [1]S.NavButtons{.{ .name = "inbox", .extra = 0, .url = "/inbox" }};
    var bh: S.BodyHeaderHtml = fr.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{
        .nav_auth = "Error",
        .nav_buttons = &btns,
    } };

    if (fr.user) |usr| {
        if (usr.username) |un| {
            bh.nav.nav_auth = un;
        } else {
            bh.nav.nav_auth = "Error No Username";
        }
    } else {
        bh.nav.nav_auth = "Public";
    }
    fr.response_data.add(bh) catch {};
    return call(fr) catch |err| switch (err) {
        error.InvalidURI => builder(fr, notFound), // TODO catch inline
        error.BrokenPipe => std.debug.print("client disconnect", .{}),
        error.IOWriteFailure => std.debug.print("Unexpected IOWriteFailure\n", .{}),
        error.Unrouteable => {
            std.debug.print("Unrouteable", .{});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
        },
        error.NotImplemented, error.Unknown => {
            std.debug.print("Unexpected error '{}'\n", .{err});
            return fr.sendDefaultErrorPage(.internal_server_error);
        },
        error.ServerFault => {
            std.debug.print("Server Fault\n", .{});
            return fr.sendDefaultErrorPage(.internal_server_error);
        },
        error.OutOfMemory,
        error.NoSpaceLeft,
        => {
            std.debug.print("Unexpected error '{}'", .{err});
            @panic("not implemented");
        },
        error.Unauthenticated => {
            return fr.sendDefaultErrorPage(.unauthorized);
        },
        error.Unauthorized => {
            return fr.sendDefaultErrorPage(.forbidden);
        },
        error.Abuse,
        error.DataInvalid,
        error.DataMissing,
        => {
            std.debug.print("Abuse {} because {}\n", .{ fr.request, err });
            fr.dumpDebugData(.{});
            if (fr.request.data.post) |post_data| {
                std.debug.print("post data => '''{s}'''\n", .{post_data.rawpost});
            }
            return fr.sendDefaultErrorPage(.bad_request);
        },
    };
}

test {
    const a = std.testing.allocator;
    const cache = @import("cache.zig");
    const ca = cache.init(a);
    defer ca.raze();

    try endpoints.smokeTest(a, .{
        .recurse = true,
        .soft_errors = &[_]Router.Error{ error.DataInvalid, error.DataMissing, error.Unrouteable },
        .retry_with_fake_user = true,
    });
}

test "fuzzing" {
    const a = std.testing.allocator;
    const cache = @import("cache.zig");
    const ca = cache.init(a);
    defer ca.raze();

    try verse.testing.fuzzTest(.{ .build = commitFlex });
}

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
