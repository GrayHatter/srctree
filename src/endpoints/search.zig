pub const verse_name = .search;

pub const verse_aliases = .{.inbox};

pub const verse_routes = [_]Routes.Match{ ROUTE("search", index), ROUTE("inbox", inbox) };

const SearchHtml = T.PageData("search.html");

const SearchReq = struct {
    q: ?[]const u8,
};

fn inbox(ctx: *Frame) Error!void {
    return custom(ctx, "owner:me is:open");
}

pub fn inboxCount(user: ?verse.Auth.User, a: Allocator, io: Io) usize {
    var inbox_count: usize = 0;
    const search_str = if (user) |_|
        "is:open owner:me"
    else
        "is:open";

    if (Search.init(search_str, a)) |search| {
        var search_results = Delta.searchAll(search.rules.items, io);
        search_results.data = if (user) |usr| .{ .user = usr.username orelse &.{} } else .empty;
        while (search_results.nextDelta(a, io)) |dlt| {
            inbox_count +|= 1;
            dlt.raze(a);
        }
    } else |_| {}

    return inbox_count;
}

pub fn genRules(_: anytype, _: anytype) !Search {
    unreachable;
}

pub fn index(f: *Frame) Error!void {
    var uri = f.uri;
    uri.index = 0;
    if (eql(u8, uri.next() orelse "", "inbox")) return inbox(f);
    const udata = f.request.data.query.validate(SearchReq) catch return error.DataInvalid;

    const query_str = udata.q orelse "";
    // TODO this comes from the URI so it should be enforced by verse
    for (query_str) |c| switch (c) {
        0...std.ascii.control_code.us => return error.DataInvalid,
        std.ascii.control_code.del => return error.DataInvalid,
        else => continue,
    };

    // FIXME
    var rules: ArrayList(Search.Rule) = .empty;
    _ = &rules;
    //const rules = try genRules(query_str, f.alloc);
    for (rules.items) |rule| switch (rule.rule) {
        .repo => |repo| {
            if (Repo.exists(repo, .public_only, f.io)) {}
            var buf: [4096]u8 = undefined;
            for (rules.items) |rl| switch (rl.rule) {
                .only => |only| switch (only) {
                    .issues => {
                        const loc = try std.fmt.bufPrint(
                            &buf,
                            "/repo/{s}/issues/search?q={f}",
                            .{ repo, Fmt{ .data = rules.items } },
                        );
                        f.redirect(loc, .found) catch unreachable;
                    },
                    .diffs => {
                        const loc = try std.fmt.bufPrint(
                            &buf,
                            "/repo/{s}/diffs/search?q={f}",
                            .{ repo, Fmt{ .data = rules.items } },
                        );
                        f.redirect(loc, .found) catch unreachable;
                    },
                    .deltas => {},
                    .commits => {},
                    .repos => {},
                    .files => {},
                },
                else => {},
            };
        },
        else => continue,
    };

    return custom(f, query_str);
}

const Fmt = std.fmt.Alt([]const Search.Rule, fmtRules);

fn fmtRules(rules: []const Search.Rule, w: *std.Io.Writer) !void {
    for (rules) |rl| switch (rl.rule) {
        .repo => |rp| try w.print("repo:{s} ", .{rp}),
        else => {},
    };

    for (rules) |rl| switch (rl.rule) {
        .is => |is| try w.print("is:{s} ", .{@tagName(is)}),
        else => {},
    };

    for (rules) |rl| switch (rl.rule) {
        .is, .repo => {},
        else => |m| try w.print("{f} ", .{m}),
    };
}

fn notImplemented(f: *Frame, search_str: []const u8) Error!void {
    var page: SearchHtml = .init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .inbox_count = inboxCount(f.user, f.alloc, f.io) },
        .count_files = 0,
        .search = .abx(search_str),
        .search_results = &.{},
        .search_meta = .{
            .repos = &.{},
            .files = &.{},
            .deltas = &.{},
            .commits = &.{},
        },
    });

    return f.sendPage(&page);
}

fn custom(f: *Frame, search_str: []const u8) Error!void {
    const search: Search = try .init(search_str, f.alloc);
    for (search.rules.items) |rule| log.warn("rule = {f}", .{rule});

    var itr = Delta.searchAll(search.rules.items, f.io);
    _ = &itr;

    const repos = try search.reposFor();
    //const commits = try search.commits();
    //const files = try search.files(undefined, f.alloc, f.io, 10);
    //const deltas = try search.deltas();
    _ = repos;
    //_ = commits;
    //_ = deltas;

    const results: []const S.SearchHtml.SearchResults = &[_]S.SearchHtml.SearchResults{
        .{ .search_flavor = .{ .repo = .{ .name = .safe("srctree") } } },
    };

    var page: SearchHtml = .init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .inbox_count = inboxCount(f.user, f.alloc, f.io) },
        //.repo_header = .{
        //    .repo_name = .abx(rd.name),
        //    .description = .abx(try f.alloc.dupe(u8, repo.description(f.alloc, f.io) catch "")),
        //    .blame = null,
        //    .git_uri = null,
        //    .upstream = null,
        //    .issue_count = dcount.issue,
        //    .diff_count = dcount.diff,
        //},
        .count_files = 0,
        .search = .abx(search_str),
        .search_results = results,
        .search_meta = .{
            .repos = &.{},
            .files = &.{},
            .deltas = &.{},
            .commits = &.{},
        },
    });

    return f.sendPage(&page);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const Io = std.Io;
const log = std.log.scoped(.search);
const splitScalar = std.mem.splitScalar;
const cutPrefix = std.mem.cutPrefix;
const trim = std.mem.trim;
const eql = std.mem.eql;
const findScalar = std.mem.findScalar;

const verse = @import("verse");
const abx = verse.Antibiotic;
const Frame = verse.Frame;
const Routes = verse.Router;
const Error = Routes.Error;
const ROUTE = Routes.ROUTE;
const T = verse.template;
const S = T.Structs;

const Repo = @import("../Repo.zig");
const Delta = @import("../types.zig").Delta;
const Search = @import("../Search.zig");
