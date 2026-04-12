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

pub fn index(ctx: *Frame) Error!void {
    const udata = ctx.request.data.query.validate(SearchReq) catch return error.DataInvalid;
    const query_str = udata.q orelse "";

    if (cutPrefix(u8, trim(u8, query_str, " "), "repo:")) |repo| {
        const len: usize = (findScalar(u8, repo, ' ') orelse repo.len) + 1;
        for (repo[0 .. len - 1]) |c| {
            switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_' => continue,
                else => break,
            }
        } else {
            var str: []const u8 = "";
            for (repo) |c| {
                // TODO this comes from the URI so it should be enforced by verse
                switch (c) {
                    0...std.ascii.control_code.us => break,
                    std.ascii.control_code.del => break,
                    else => continue,
                }
            } else str = repo[len - 1 ..];
            var buf: [4096]u8 = undefined;
            const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/search?q={s}", .{ repo[0 .. len - 1], str });
            ctx.redirect(loc, .found) catch unreachable;
        }
    }

    return custom(ctx, query_str);
}

pub fn genRules(search_str: []const u8, a: Allocator) !ArrayList(Tsearch.Rule) {
    var rules: ArrayList(Tsearch.Rule) = .{};
    {
        var itr = splitScalar(u8, search_str, ' ');
        while (itr.next()) |r_line| {
            var line = r_line;
            line = std.mem.trim(u8, line, " ");
            if (line.len == 0) continue;
            try rules.append(a, .parse(line));
        }
    }
    return rules;
}

fn custom(f: *Frame, search_str: []const u8) Error!void {
    const rules = try genRules(search_str, f.alloc);
    for (rules.items) |rule| {
        log.warn("rule = {f}", .{rule});
    }

    var itr = Delta.search(rules.items, f.io);

    try delta_shared.list(f, Delta.Iterator, &itr, try allocPrint(f.alloc, "{f}", .{
        abx.Html{ .text = search_str },
    }));
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const log = std.log.scoped(.search);
const splitScalar = std.mem.splitScalar;
const cutPrefix = std.mem.cutPrefix;
const trim = std.mem.trim;
const findScalar = std.mem.findScalar;
const allocPrint = std.fmt.allocPrint;

const verse = @import("verse");
const abx = verse.abx;
const Frame = verse.Frame;
const Routes = verse.Router;
const Error = Routes.Error;
const ROUTE = Routes.ROUTE;

const Delta = @import("../types.zig").Delta;
const Tsearch = @import("../types/search.zig");
const delta_shared = @import("delta.zig");
