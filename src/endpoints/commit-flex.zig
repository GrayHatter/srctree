const std = @import("std");

const Allocator = std.mem.Allocator;

const DateTime = @import("../datetime.zig");
const Endpoint = @import("../endpoint.zig");
const Git = @import("../git.zig");
const Ini = @import("../ini.zig");

const DOM = Endpoint.DOM;
const HTML = Endpoint.HTML;
const Context = Endpoint.Context;
const Template = Endpoint.Template;

const Error = Endpoint.Error;

/// we might add up to 6 days to align the grid
const HeatMapArray = [366 + 6]u16;

var hits: HeatMapArray = .{0} ** (366 + 6);
var seen: ?std.BufSet = null;

var owner_email: ?[]const u8 = null;

fn reset_hits(a: Allocator) void {
    @memset(&hits, 0);
    seen = std.BufSet.init(a);
}

fn countAll(a: Allocator, until: i64, root_cmt: Git.Commit) !*HeatMapArray {
    var commit = root_cmt;
    while (true) {
        if (seen.?.contains(commit.sha)) return &hits;
        var commit_time = commit.author.timestamp;
        if (DateTime.tzToSec(commit.author.tzstr) catch @as(?i32, 0)) |tzs| {
            commit_time += tzs;
        }

        if (commit_time < until) return &hits;
        const day_off: usize = @abs(@divFloor(commit_time - until, DAY));
        if (owner_email) |email| {
            if (std.mem.eql(u8, email, commit.author.email)) {
                hits[day_off] += 1;
                //std.log.info("BAH! {}", .{commit});
            }
        } else hits[day_off] += 1;
        for (commit.parent[1..], 1..) |par, pidx| {
            if (par) |_| {
                seen.?.insert(par.?) catch return &hits;
                const parent = try commit.toParent(a, @truncate(pidx));
                //defer parent.raze(a);
                _ = try countAll(a, until, parent);
            }
        }
        commit = commit.toParent(a, 0) catch |err| switch (err) {
            error.NoParent => return &hits,
            else => |e| return e,
        };
    }
}

fn findCommits(a: Allocator, until: i64, gitdir: []const u8) !*HeatMapArray {
    const repo_dir = try std.fs.cwd().openDir(gitdir, .{});
    var repo = try Git.Repo.init(repo_dir);
    try repo.loadData(a);
    defer repo.raze(a);

    const commit = repo.commit(a) catch return &hits;
    return try countAll(a, until, commit);
}

const DAY = 60 * 60 * 24;
const WEEK = DAY * 7;
const YEAR = 31_536_000;

pub fn commitFlex(ctx: *Context) Error!void {
    const day = HTML.Attr.class("day");
    const monthAtt = HTML.Attr.class("month");

    var nowish = DateTime.now();
    var date = DateTime.today();
    date = DateTime.fromEpoch(date.timestamp + DAY - YEAR) catch unreachable;
    while (date.weekday != 0) {
        date = DateTime.fromEpoch(date.timestamp - DAY) catch unreachable;
    }
    const until = date.timestamp;

    var repo_count: usize = 0;
    var cwd = std.fs.cwd();
    if (cwd.openDir("./repos", .{ .iterate = true })) |idir| {
        reset_hits(ctx.alloc);
        if (Ini.default(ctx.alloc)) |ini| {
            if (ini.get("owner")) |ns| {
                if (ns.get("email")) |email| {
                    owner_email = email;
                }
                if (ns.get("tz")) |ts| {
                    if (DateTime.tzToSec(ts) catch @as(?i32, 0)) |tzs| {
                        nowish = DateTime.fromEpoch(nowish.timestamp + tzs) catch unreachable;
                    }
                }
            }
        } else |_| {}
        defer owner_email = null;

        var itr = idir.iterate();
        while (itr.next() catch return Error.Unknown) |file| {
            var buf: [1024]u8 = undefined;
            switch (file.kind) {
                .directory, .sym_link => {
                    const name = std.fmt.bufPrint(&buf, "./repos/{s}", .{file.name}) catch return Error.Unknown;
                    _ = findCommits(ctx.alloc, until, name) catch unreachable;
                    repo_count +|= 1;
                },
                else => {},
            }
        }
    } else |_| unreachable;

    var dom = DOM.new(ctx.alloc);
    var tcount: u16 = 0;
    for (hits) |h| tcount +|= h;
    var hit_total_buf: [0x40]u8 = undefined;
    const hit_total_str = std.fmt.bufPrint(
        &hit_total_buf,
        "{} commits across {} repos",
        .{ tcount, repo_count },
    ) catch unreachable;
    dom.push(HTML.h3(hit_total_str, null));

    dom = dom.open(HTML.div(null, &HTML.Attr.class("commit-flex")));

    dom = dom.open(HTML.div(null, &HTML.Attr.class("day-col")));
    dom.push(HTML.div("&nbsp;", &day));
    dom.push(HTML.div("Sun", &day));
    dom.push(HTML.div("Mon", &day));
    dom.push(HTML.div("Tue", &day));
    dom.push(HTML.div("Wed", &day));
    dom.push(HTML.div("Thr", &day));
    dom.push(HTML.div("Fri", &day));
    dom.push(HTML.div("Sat", &day));
    dom = dom.close();

    var printed_month: usize = (date.months + 10) % 12;
    var day_off: usize = 0;
    for (0..53) |_| {
        var month: []HTML.Element = try ctx.alloc.alloc(HTML.Element, 8);
        if ((printed_month % 12) != date.months - 1) {
            const next_week = DateTime.fromEpoch(date.timestamp + WEEK) catch unreachable;
            printed_month += 1;
            if ((printed_month % 12) != next_week.months - 1) {
                month[0] = HTML.div("&nbsp;", &monthAtt);
            } else {
                month[0] = HTML.div(DateTime.MONTHS[printed_month % 12 + 1][0..3], &monthAtt);
            }
        } else {
            month[0] = HTML.div("&nbsp;", &monthAtt);
        }

        for (month[1..]) |*m| {
            defer date = DateTime.fromEpoch(date.timestamp + DAY) catch unreachable;
            defer day_off += 1;
            const rows = try ctx.alloc.alloc(HTML.Attribute, 2);
            const class = if (date.timestamp >= nowish.timestamp)
                "day-hide"
            else switch (16 - @clz(hits[day_off])) {
                0 => "day",
                1 => "day day-commits day-pwr-1",
                2 => "day day-commits day-pwr-2",
                3 => "day day-commits day-pwr-3",
                4 => "day day-commits day-pwr-4",
                5 => "day day-commits day-pwr-5",
                else => "day day-commits day-pwr-max",
            };
            @memcpy(rows, &[2]HTML.Attr{
                HTML.Attr.class(class)[0],
                HTML.Attr{
                    .key = "title",
                    .value = try std.fmt.allocPrint(
                        ctx.alloc,
                        "{} commits on {}",
                        .{ hits[day_off], date },
                    ),
                },
            });
            m.* = HTML.div(null, rows);
        }
        dom.push(HTML.div(month, &HTML.Attr.class("col")));
    }
    dom = dom.close();

    const flex = dom.done();

    var tmpl = Template.find("user_commits.html");
    tmpl.init(ctx.alloc);

    _ = tmpl.addElements(ctx.alloc, "Flexes", flex) catch return Error.Unknown;
    return ctx.sendTemplate(&tmpl) catch unreachable;
}
