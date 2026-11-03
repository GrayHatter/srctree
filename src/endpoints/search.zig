pub const verse_name = .search;

pub const verse_aliases = .{.inbox};

pub const verse_routes = [_]Routes.Match{
    ROUTE("search", index),
    ROUTE("inbox", inbox),
};

const SearchHtml = T.PageData("search.html");

const SearchReq = struct {
    q: ?[]const u8,
};

const default_search = "only:deltas is:open owner:me";
fn inbox(f: *Frame) Error!void {
    const search_str = if (f.user) |_| default_search else default_search[0..19];
    return custom(f, search_str);
}

pub fn inboxCount(user: ?verse.Auth.User, a: Allocator, io: Io) usize {
    var inbox_count: usize = 0;
    const search_str = if (user) |_| default_search else default_search[0..19];

    if (Search.init(search_str, .quick, a)) |search| {
        var search_results = Delta.searchAll(search.rules.items, io);
        defer search_results.raze(io);
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
    //const rules = try genRules(query_str, f.alloc);
    //for (rules.items) |rule| switch (rule.rule) {
    //    .repo => |repo| {
    //        if (Repo.exists(repo, .public_only, f.io)) {}
    //        var buf: [4096]u8 = undefined;
    //        for (rules.items) |rl| switch (rl.rule) {
    //            .only => |only| switch (only) {
    //                .issues => {
    //                    const loc = try std.fmt.bufPrint(
    //                        &buf,
    //                        "/repo/{s}/issues/search?q={f}",
    //                        .{ repo, Fmt{ .data = rules.items } },
    //                    );
    //                    f.redirect(loc, .found) catch unreachable;
    //                },
    //                .diffs => {
    //                    const loc = try std.fmt.bufPrint(
    //                        &buf,
    //                        "/repo/{s}/diffs/search?q={f}",
    //                        .{ repo, Fmt{ .data = rules.items } },
    //                    );
    //                    f.redirect(loc, .found) catch unreachable;
    //                },
    //                .deltas => {},
    //                .commits => {},
    //                .repos => {},
    //                .files => {},
    //            },
    //            else => {},
    //        };
    //    },
    //    else => continue,
    //};

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

fn errorPage(f: *Frame, search_str: []const u8, err: []const u8) Error!void {
    var page: SearchHtml = .init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = (f.template_data.get(S.BodyHeaderHtml) orelse
            &S.BodyHeaderHtml{ .inbox_count = inboxCount(f.user, f.alloc, f.io) }).*,
        .result_count = 0,
        .checked_count = 0,
        .search = .abx(search_str),
        .error_string = .{ .string = .safe(err) },
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

const MetaRepo = S.SearchHtml.SearchMeta.Repos;
const MetaDelta = S.SearchHtml.SearchMeta.Deltas;
const MetaFile = S.SearchHtml.SearchMeta.Files;

pub fn custom(f: *Frame, query_str: []const u8) Error!void {
    var search: Search = Search.init(query_str, .quick, f.alloc) catch
        return errorPage(f, query_str, "Bad Search Terms");
    defer search.raze(f.io);
    for (search.rules.items) |rule| log.warn("rule = {f}", .{rule});

    search.searchAll(f.io) catch return error.ServerFault;
    log.err("repos = {}", .{search.repos.items.len});

    var show_meta: bool = true;
    if (search.only) |_| {
        if (search.repo) |_| {
            show_meta = false;
        }
    }

    var results: ArrayList(S.SearchHtml.SearchResults) = .empty;

    for (search.hits.items) |*hit| switch (hit.result) {
        .repo => |repo| try results.append(f.alloc, .{ .search_flavor = .{
            .repo = .{ .name = .safe(repo.name.?) },
        } }),
        .delta => |d| try results.append(f.alloc, .{
            .search_flavor = .{ .delta = delta_endpoint.deltaResult(d, .zero, search.alloc, f.io) catch continue },
        }),
        .commit => |*c| try results.append(f.alloc, .{
            .search_flavor = .{ .commit = .{
                .repo_name = .safe(c.repo_name),
                .sha = .safe(c.sha.slice()[0..10]),
                .title = .abx(c.title),
                .body = .abx(c.body),
            } },
        }),
        .file => |*path| try results.append(f.alloc, .{
            .search_flavor = .{
                .file = .{
                    .repo_name = .safe(path.repo_name),
                    // TODO ref/sha/name
                    //.sha = .safe(path.sha.slice()[0..10]),
                    .filename = .abx(path.path),
                    .code = if (path.code.len > 0) .{ .lines = .abx(path.code) } else null,
                    .line = path.line,
                },
            },
        }),
    };

    var repos: ArrayList(MetaRepo) = .empty;
    var deltas: ArrayList(MetaDelta) = .empty;
    //const commits : ArrayList(S) = .empty;
    var files: ArrayList(MetaFile) = .empty;
    if (show_meta) {
        {
            var itr = search.meta.repos.iterator();
            while (itr.next()) |next| {
                try repos.append(f.alloc, .{ .name = .safe(next.key_ptr.*), .count = next.value_ptr.* });
            }
        }
        {
            var itr = search.meta.deltas.iterator();
            while (itr.next()) |next| {
                try deltas.append(f.alloc, .{ .name = .safe(next.key_ptr.*), .count = next.value_ptr.* });
            }
        }
        {
            var itr = search.meta.files.iterator();
            while (itr.next()) |next| {
                try files.append(f.alloc, .{
                    .name = .safe(next.key_ptr.*),
                    .count = next.value_ptr.*,
                });
            }
        }
    }

    var page: SearchHtml = .init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = (f.template_data.get(S.BodyHeaderHtml) orelse
            &S.BodyHeaderHtml{ .inbox_count = inboxCount(f.user, f.alloc, f.io) }).*,
        .result_count = search.hits.items.len,
        .checked_count = search.meta.checked,
        .search = .abx(query_str),
        .search_results = results.items,
        .search_meta = if (!show_meta) null else .{
            .repos = repos.items,
            .deltas = deltas.items,
            .commits = &.{},
            .files = files.items,
            .file_exclusion = if (search.full_term_count == 0)
                .safe("<br>File text search requires<br> at least one search term")
            else
                null,
        },
        .error_string = null,
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

const delta_endpoint = @import("delta.zig");
const Repo = @import("../Repo.zig");
const Delta = @import("../types.zig").Delta;
const Search = @import("../Search.zig");
