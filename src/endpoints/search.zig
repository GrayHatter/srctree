pub const verse_name = .search;

pub const verse_aliases = .{
    .inbox,
};

pub const verse_routes = [_]Routes.Match{
    ROUTE("search", index),
    ROUTE("inbox", inbox),
};

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
    if (genRules(search_str, a)) |rules| {
        var search_results = Delta.search(rules.items, io);
        search_results.data = if (user) |usr| .{ .user = usr.username orelse &.{} } else .empty;
        while (search_results.next(a, io)) |dlt| {
            inbox_count +|= 1;
            dlt.raze(a);
        }
    } else |_| {}

    return inbox_count;
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

    const rules = try genRules(query_str, f.alloc);
    for (rules.items) |rule| switch (rule.match) {
        .repo => |repo| {
            if (Repo.exists(repo, .public_only, f.io)) {}
            var buf: [4096]u8 = undefined;
            for (rules.items) |rl| switch (rl.match) {
                .is => |is| {
                    if (eql(u8, is, "issue")) {
                        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/search?q={f}", .{ repo, Fmt{ .data = rules.items } });
                        f.redirect(loc, .found) catch unreachable;
                    } else if (eql(u8, is, "diff")) {
                        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/diffs/search?q={f}", .{ repo, Fmt{ .data = rules.items } });
                        f.redirect(loc, .found) catch unreachable;
                    }
                },
                else => {},
            };
        },
        else => continue,
    };

    return custom(f, query_str);
}

const Fmt = std.fmt.Alt([]const Tsearch.Rule, fmtRules);

fn fmtRules(rules: []const Tsearch.Rule, w: *std.Io.Writer) !void {
    for (rules) |rl| switch (rl.match) {
        .repo => |rp| try w.print("repo:{s} ", .{rp}),
        else => {},
    };

    for (rules) |rl| switch (rl.match) {
        .is => |is| try w.print("is:{s} ", .{is}),
        else => {},
    };

    for (rules) |rl| switch (rl.match) {
        .is, .repo => {},
        else => |m| try w.print("{f} ", .{m}),
    };
}

pub const RulesList = ArrayList(Tsearch.Rule);

pub fn genRules(search_str: []const u8, a: Allocator) !RulesList {
    var rules: RulesList = .empty;
    var itr = splitScalar(u8, search_str, ' ');
    while (itr.next()) |r_line| {
        var line = r_line;
        line = trim(u8, line, " ");
        if (line.len == 0) continue;
        try rules.append(a, .parse(line));
    }
    return rules;
}

fn custom(f: *Frame, search_str: []const u8) Error!void {
    const rules = try genRules(search_str, f.alloc);
    for (rules.items) |rule| log.warn("rule = {f}", .{rule});

    var itr = Delta.search(rules.items, f.io);

    try delta_shared.list(f, Delta.Iterator, &itr, .abx(search_str));
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
const allocPrint = std.fmt.allocPrint;

const verse = @import("verse");
const abx = verse.Antibiotic;
const Frame = verse.Frame;
const Routes = verse.Router;
const Error = Routes.Error;
const ROUTE = Routes.ROUTE;

const Repo = @import("../Repo.zig");
const Delta = @import("../types.zig").Delta;
const Tsearch = @import("../types/search.zig");
const delta_shared = @import("delta.zig");
