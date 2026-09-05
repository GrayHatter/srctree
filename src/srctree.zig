const root = @This();

pub const verse_name = .root;
pub const verse_routes = [_]Match{
    robots_txt,
    GET("debug", debug),
    ROUTE("user", commitFlex),
    STATIC("static"),
};
pub const verse_builder = &builder;
pub const index = commitFlex;

pub const endpoints = verse.Endpoints(.{
    root,
    verse.Stats.Endpoint,
    @import("endpoints/api.zig"),
    @import("endpoints/auth.zig"),
    @import("endpoints/admin.zig"),
    @import("endpoints/gist.zig"),
    @import("endpoints/network.zig"),
    @import("endpoints/repos.zig"),
    @import("endpoints/search.zig"),
    @import("endpoints/debugging.zig"),
});

const E404Page = template.PageData("4XX.html");

fn notFound(vrs: *Frame) Router.Error!void {
    vrs.status = .not_found;
    var page = E404Page.init(true);
    vrs.sendPage(&page) catch unreachable;
}

fn debug(_: *Frame) Router.Error!void {
    return error.ServerFault;
}

fn dropRequest(f: *Frame, comptime reason: []const u8) BuildFn {
    log.err("Dropping traffic: " ++ reason, .{});
    if (global_config.server) |srv| {
        if (srv.debug_blocked_traffic) {
            f.dumpDebugData(.{});
            if (f.request.user_agent) |ua|
                ua.dumpValidation(f.request);
        }
    } else {
        f.dumpDebugData(.{});
        if (f.request.user_agent) |ua|
            ua.dumpValidation(f.request);
    }

    return notFound;
}

inline fn botRequest(f: *Frame, ua: *const verse.Request.UserAgent) ?BuildFn {
    const bot = ua.agent.bot;
    switch (f.downstream.gateway) {
        .zwsgi => |zw| if (zw.known.get(.SERVER_PORT)) |port|
            if (eql(u8, port, "444")) return dropRequest(f, "bad port"),
        else => {},
    }
    switch (bot.name) {
        .googlebot => return null,
        .bingbot => return null,

        inline .gptbot,
        .metaexternalagent,
        .scrybot,
        .youbot,
        .reflectionbot,
        => |t| return dropRequest(f, @tagName(t) ++ "ignores robots.txt"),
        .unknown => {
            if (find(u8, ua.string, "SearchBot/1.0")) |_| return dropRequest(f, "ignores robots.txt");
            if (find(u8, ua.string, "SleepBot/1.0")) |_| return dropRequest(f, "ignores robots.txt");
            return null;
        },

        else => {
            if (global_config.server) |srv| {
                if (srv.debug_blocked_traffic)
                    f.dumpDebugData(.{});
            }

            const ua_str = f.request.user_agent.?.string;
            const ia_ua = "Mozilla/5.0 (X11; Linux x86_64; rv:144.0) Gecko/20100101 Firefox/144.0";
            const ia_bot_ua = find(u8, ua_str, ia_ua) == null;
            if (bot.malicious and !ia_bot_ua) {
                log.err("Dropping other malicious bot traffic", .{});
                return Router.defaultResponse(.forbidden);
            }
        },
    }
    return null;
}

inline fn browserRequest(f: *Frame, ua: *const verse.Request.UserAgent) ?BuildFn {
    const bwsr = ua.agent.browser;
    switch (f.downstream.gateway) {
        .zwsgi => |zw| if (zw.known.get(.SERVER_PORT)) |port|
            if (eql(u8, port, "444"))
                return dropRequest(f, "bad port"),
        else => {},
    }

    // hastur
    const botdetect: verse.Robots = .init(f.request);
    const real_ua = ua.validate(f.request);
    if ((botdetect.score >= 1 or (real_ua.agent == .bot and
        real_ua.agent.bot.name == .malicious)) and
        ua.agent.browser.version != 128)
    {
        return dropRequest(f, "Malicious score");
    }
    // super abusive bot
    if ((bwsr.name == .chrome or bwsr.name == .edge) and
        bwsr.version <= 137 and bwsr.version >= 130)
        return dropRequest(f, "manual bot detection");

    if (f.request.accept.encoding == null and bwsr.name == .firefox) {
        return dropRequest(f, "ff missing encoding");
    }

    const bads = [_][]const u8{
        \\"Not;A=Brand";v="8"
        ,
        \\"Chromium";v="143", "Google Chrome";v="143", "Not_A Brand";v="99"
        ,
        \\"Chromium";v="148", "Google Chrome";v="148", "Not/A)Brand";v="99"
        ,
        \\"Chromium";v="146", "Not-A.Brand";v="24", "Google Chrome";v="146"
        ,
        \\"Google Chrome";v="149", "Chromium";v="149", "Not)A;Brand";v="24"
        ,
        \\"Chromium";v="148", "Microsoft Edge";v="148", "Not/A)Brand";v="99"
        ,
        \\"Not_A Brand";v="8", "Chromium";v=
        ,
        \\"Not/A)Brand";v="99", "Chromium";v=
        ,
    };
    inline for (bads) |bad| {
        if (f.request.headers.getCustomValue("HTTP_SEC_CH_UA") catch null) |val| {
            if (startsWith(u8, val, bad))
                return dropRequest(f, "banned client hint");
        }
    }

    const age: std.Io.Duration = bwsr.age(f.request.now) catch .fromSeconds(0);
    const too_old = age.nanoseconds > std.Io.Duration.fromSeconds(86400 * 200).nanoseconds;
    if (too_old) return dropRequest(f, "too old");

    f.dumpDebugData(.{});
    return null;
}

fn trafficFilter(fr: *Frame) ?BuildFn {
    if (global_config.server) |srv|
        if (!srv.block_scripted_traffic)
            return null;

    if (fr.user != null) return null;

    if (fr.request.referer) |ref| {
        if (startsWith(u8, ref, "https://www.google.com/search?q=gr")) {
            return dropRequest(fr, "search string");
        }
    }

    if (eql(u8, fr.uri.path, "/robots.txt") or eql(u8, fr.uri.path, "robots.txt")) {
        fr.dumpDebugData(.{});
        return null;
    }

    if (fr.request.user_agent) |*ua| {
        switch (ua.agent) {
            .bot => return botRequest(fr, ua),
            .browser => return browserRequest(fr, ua),
            .unknown => if (startsWith(u8, fr.request.user_agent.?.string, "Opera/"))
                return dropRequest(fr, "opera"),
            .script => {},
        }
        return null;
    }

    log.err("No User agent for request\n\n\n\n", .{});
    fr.dumpDebugData(.{});
    return null;
}

fn builder(fr: *Frame, call: BuildFn) void {
    fr.downstream.phase = .{ .responding = .new };

    if (trafficFilter(fr)) |resol| {
        return resol(fr) catch {};
    }

    var inbox_count: usize = 0;
    const search_str = if (fr.user) |_|
        "is:open owner:me"
    else
        "is:open";
    if (genRules(search_str, fr.alloc)) |rules| {
        var search_results = Delta.search(rules.items, fr.io);
        search_results.data = if (fr.user) |usr| .{ .user = usr.username orelse &.{} } else .empty;
        while (search_results.next(fr.alloc, fr.io)) |dlt| {
            inbox_count +|= 1;
            dlt.raze(fr.alloc);
        }
    } else |_| {}

    const btns = [1]S.NavButtons{.{
        .name = .safe("inbox"),
        .extra = inbox_count,
        .url = .safe("/inbox"),
    }};
    var bh: S.BodyHeaderHtml = (fr.response_data.get(S.BodyHeaderHtml) orelse &S.BodyHeaderHtml{ .nav = .{
        .nav_auth = "Error",
        .nav_buttons = &btns,
    } }).*;

    if (fr.user) |usr| {
        bh.nav.nav_auth = if (usr.username) |un| un else "Error No Username";
    } else {
        bh.nav.nav_auth = "Public";
    }

    fr.response_data.clone(S.BodyHeaderHtml, fr.alloc, bh) catch {};
    return call(fr) catch |err| switch (err) {
        error.NotFound => builder(fr, notFound), // TODO catch inline
        error.InvalidURI => builder(fr, notFound), // TODO catch inline
        error.WriteFailed => log.err("Unexpected WriteFailure", .{}),
        error.NotImplemented, error.Unknown => {
            log.err("Unexpected error '{}'", .{err});
            if (@import("builtin").mode == .Debug) unreachable;
            return fr.sendDefaultErrorPage(.internal_server_error);
        },
        error.ServerFault => {
            log.err("Server Fault", .{});
            if (@import("builtin").mode == .Debug) unreachable;
            return fr.sendDefaultErrorPage(.internal_server_error);
        },
        error.OutOfMemory, error.NoSpaceLeft => {
            log.err("Unexpected error '{}'", .{err});
            @panic("not implemented");
        },
        error.Unauthenticated => return fr.sendDefaultErrorPage(.unauthorized),
        error.Unauthorized => return fr.sendDefaultErrorPage(.forbidden),
        error.Abuse,
        error.DataInvalid,
        error.DataMissing,
        => {
            std.debug.print("Abuse {} because {}\n", .{ fr.request, err });
            fr.dumpDebugData(.{});
            if (fr.request.data.post) |post_data| {
                std.debug.print("post data => '''{s}'''\n", .{post_data.source});
            }
            return fr.sendDefaultErrorPage(.bad_request);
        },
    };
}

const robots_txt = verse.Robots.robotsTxt(
    &.{
        .{ .name = "GoogleOther", .allow = false }, // aggressive genai bot
        .{ .name = "SiteAuditBot", .allow = false }, // selfish bot
        .{ .name = "DataForSeoBot", .allow = false }, // selfish bot
        .{ .name = "Zoominfobot", .allow = false }, // selfish bot
        .{ .name = "BacklinksExtendedBot", .allow = false }, // selfish bot
        .{ .name = "barkrowler", .allow = false }, // selfish bot
        .{ .name = "ClaudeBot", .allow = false }, // aggressive, selfish
        .{ .name = "GPTBot", .allow = false }, // aggressive, selfish
        .{ .name = "OAI-SearchBot", .allow = false },
        .{ .name = "meta-externalagent", .allow = false }, // agressive

        // If you're the kind of person who enables this, you're part of the problem
        .{ .name = "Amazonbot", .allow = false }, // aggressive, malicious
        .{ .name = "Amzn-SearchBot", .allow = false }, //  malicious
        .{ .name = "Amzn-User", .allow = false }, // malicious

        .{ .name = "SleepBot", .allow = false },

        .{ .name = "ScryBot", .allow = false },

        .{ .name = "AppleBot", .allow = true, .extra = "Disallow: /static/*\n" },
        .{ .name = "AhrefsBot", .allow = false }, // selfish
        .{ .name = "dotbot", .allow = false }, // selfish
        .{ .name = "PerplexityBot", .allow = false },
        // Disallowed for being too aggressive, and substituting it's own crawl delay
        .{ .name = "MJ12bot", .allow = false, .extra = "Crawl-Delay: 90\n" },
        .{ .name = "ImagesiftBot", .allow = true },
        .{ .name = "AcademicBotRTU", .allow = false },
        .{ .name = "CCBot", .allow = false }, // One day I'll learn to not assume good faith
    },
    .{ .extra_rules = "Disallow: /*?*\nDisallow: /repo/*/blame/*\n" },
);

test {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const cache = @import("cache.zig");
    const ca = cache.init(a);
    defer ca.raze();

    const Types = @import("types.zig");

    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init((try tempdir.dir.createDirPathOpen(io, "datadir", .{})), io);
    defer Types.raze(io);

    try endpoints.smokeTest(a, .{
        .recurse = true,
        .soft_errors = &[_]Router.Error{ error.DataInvalid, error.DataMissing },
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
const find = std.mem.find;

const startsWith = std.mem.startsWith;
const log = std.log.scoped(.srctree);

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

const Delta = @import("types.zig").Delta;
const genRules = @import("endpoints/search.zig").genRules;
const commitFlex = @import("endpoints/commit-flex.zig").commitFlex;

const global_config = &@import("Config.zig").global;
