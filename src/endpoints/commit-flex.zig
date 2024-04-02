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

const Scribe = struct {
    const Commit = struct {
        name: []const u8,
        repo: []const u8,
        title: []const u8,
        date: DateTime,
        sha: []const u8,

        pub fn toContext(self: Commit, a: Allocator) !Template.Context {
            var jctx = Template.Context.init(a);
            try jctx.put("Name", self.name);
            try jctx.put("Repo", self.repo);
            try jctx.put("Title", self.title);
            try jctx.put("Date", try std.fmt.allocPrint(a, "{}", .{self.date}));
            try jctx.put("Sha", self.sha);
            return jctx;
        }
    };

    const Option = union(enum) {
        commit: Commit,
    };

    thing: Option,
};

/// we might add up to 6 days to align the grid
const HeatMapArray = [366 + 6]u16;

fn countAll(
    a: Allocator,
    hits: *HeatMapArray,
    seen: *std.BufSet,
    until: i64,
    root_cmt: Git.Commit,
    email: ?[]const u8,
) !*HeatMapArray {
    var commit = root_cmt;
    while (true) {
        if (seen.contains(commit.sha)) return hits;
        var commit_time = commit.author.timestamp;
        if (DateTime.tzToSec(commit.author.tzstr) catch @as(?i32, 0)) |tzs| {
            commit_time += tzs;
        }

        if (commit_time < until) return hits;
        const day_off: usize = @abs(@divFloor(commit_time - until, DAY));
        if (email) |email_| {
            if (std.mem.eql(u8, email_, commit.author.email)) {
                hits[day_off] += 1;
            }
        } else hits[day_off] += 1;
        for (commit.parent[1..], 1..) |par, pidx| {
            if (par) |_| {
                seen.insert(par.?) catch return hits;
                const parent = try commit.toParent(a, @truncate(pidx));
                //defer parent.raze(a);
                _ = try countAll(a, hits, seen, until, parent, email);
            }
        }
        commit = commit.toParent(a, 0) catch |err| switch (err) {
            error.NoParent => return hits,
            else => |e| return e,
        };
    }
}

fn journalLessThan(_: void, left: Scribe.Commit, right: Scribe.Commit) bool {
    if (left.date.timestamp < right.date.timestamp) return true;
    if (left.date.timestamp > right.date.timestamp) return false;
    if (left.repo.len < right.repo.len) return true;
    return false;
}

fn journalSorted(_: void, left: Scribe.Commit, right: Scribe.Commit) bool {
    return !journalLessThan({}, left, right);
}

fn buildJournal(
    a: Allocator,
    list: *std.ArrayList(Scribe.Commit),
    email: ?[]const u8,
    gitdir: []const u8,
) !void {
    const repo_dir = try std.fs.cwd().openDir(gitdir, .{});
    var repo = try Git.Repo.init(repo_dir);
    try repo.loadData(a);
    defer repo.raze(a);

    var lseen = std.BufSet.init(a);
    const until = (DateTime.fromEpoch(DateTime.now().timestamp - DAY * 90)).timestamp;
    var commit = try repo.commit(a);

    while (true) {
        if (lseen.contains(commit.sha)) break;
        var commit_time = commit.author.timestamp;
        if (DateTime.tzToSec(commit.author.tzstr) catch @as(?i32, 0)) |tzs| {
            commit_time += tzs;
        }
        if (commit_time < until) break;
        if (std.mem.eql(u8, email.?, commit.author.email)) {
            try list.append(.{
                .name = try a.dupe(u8, commit.author.name),
                .title = try a.dupe(u8, commit.title),
                .date = DateTime.fromEpoch(commit_time),
                .sha = try a.dupe(u8, commit.sha),
                .repo = try a.dupe(u8, gitdir[8..]),
            });
        }

        //for (commit.parent[1..], 1..) |par, pidx| {
        //    if (par) |_| {
        //        lseen.insert(par.?) catch break;
        //        const parent = try commit.toParent(a, @truncate(pidx));
        //        //defer parent.raze(a);
        //        _ = try countAll(a, hits, seen, until, parent, email);
        //    }
        //}
        commit = commit.toParent(a, 0) catch |err| switch (err) {
            error.NoParent => break,
            else => |e| return e,
        };
    }
}

fn findCommits(a: Allocator, hits: *HeatMapArray, seen: *std.BufSet, until: i64, gitdir: []const u8, email: ?[]const u8) !*HeatMapArray {
    const repo_dir = try std.fs.cwd().openDir(gitdir, .{});
    var repo = try Git.Repo.init(repo_dir);
    try repo.loadData(a);
    defer repo.raze(a);

    const commit = repo.commit(a) catch return hits;
    return try countAll(a, hits, seen, until, commit, email);
}

const DAY = 60 * 60 * 24;
const WEEK = DAY * 7;
const YEAR = 31_536_000;

pub fn commitFlex(ctx: *Context) Error!void {
    const monthAtt = HTML.Attr.class("month");

    var nowish = DateTime.now();
    var date = DateTime.today();
    date = DateTime.fromEpoch(date.timestamp + DAY - YEAR);
    while (date.weekday != 0) {
        date = DateTime.fromEpoch(date.timestamp - DAY);
    }
    const until = date.timestamp;

    var email: ?[]const u8 = null;
    var tz_offset: ?i32 = null;
    if (Ini.default(ctx.alloc)) |ini| {
        if (ini.get("owner")) |ns| {
            if (ns.get("email")) |c_email| {
                email = c_email;
            }
            if (ns.get("tz")) |ts| {
                if (DateTime.tzToSec(ts) catch @as(?i32, 0)) |tzs| {
                    tz_offset = tzs;
                    nowish = DateTime.fromEpoch(nowish.timestamp + tzs);
                }
            }
        }
    } else |_| {}

    var hits: HeatMapArray = .{0} ** (366 + 6);
    var seen = std.BufSet.init(ctx.alloc);
    var repo_count: usize = 0;
    var dir = std.fs.cwd().openDir("./repos", .{ .iterate = true }) catch {
        return error.Unknown;
    };

    var scribe_list = std.ArrayList(Scribe.Commit).init(ctx.alloc);

    var itr = dir.iterate();
    while (itr.next() catch return Error.Unknown) |file| {
        var buf: [1024]u8 = undefined;
        switch (file.kind) {
            .directory, .sym_link => {
                const repo = std.fmt.bufPrint(&buf, "./repos/{s}", .{file.name}) catch return Error.Unknown;
                _ = findCommits(ctx.alloc, &hits, &seen, until, repo, email) catch unreachable;
                buildJournal(ctx.alloc, &scribe_list, email, repo) catch {
                    return error.Unknown;
                };
                repo_count +|= 1;
            },
            else => {},
        }
    }

    var dom = DOM.new(ctx.alloc);
    var tcount: u16 = 0;
    for (hits) |h| tcount +|= h;

    var printed_month: usize = (date.months + 10) % 12;
    var day_off: usize = 0;
    for (0..53) |_| {
        var column: []HTML.Element = try ctx.alloc.alloc(HTML.Element, 8);
        if ((printed_month % 12) != date.months - 1) {
            const next_week = DateTime.fromEpoch(date.timestamp + WEEK);
            printed_month += 1;
            if ((printed_month % 12) != next_week.months - 1) {
                column[0] = HTML.div("&nbsp;", &monthAtt);
            } else {
                column[0] = HTML.div(DateTime.MONTHS[printed_month % 12 + 1][0..3], &monthAtt);
            }
        } else {
            column[0] = HTML.div("&nbsp;", &monthAtt);
        }

        for (column[1..]) |*m| {
            defer date = DateTime.fromEpoch(date.timestamp + DAY);
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
        dom.push(HTML.div(column, &HTML.Attr.class("col")));
    }

    const flex = dom.done();

    var tmpl = Template.find("user_commits.html");
    tmpl.init(ctx.alloc);

    try tmpl.ctx.?.put("Total_hits", try std.fmt.allocPrint(ctx.alloc, "{}", .{tcount}));
    try tmpl.ctx.?.put("Checked_repos", try std.fmt.allocPrint(ctx.alloc, "{}", .{repo_count}));
    _ = tmpl.addElements(ctx.alloc, "Flexes", flex) catch return Error.Unknown;

    std.sort.pdq(Scribe.Commit, scribe_list.items, {}, journalSorted);

    {
        const today = if (tz_offset) |tz|
            DateTime.fromEpoch(DateTime.today().timestamp + tz).removeTime()
        else
            DateTime.today();
        const yesterday = DateTime.fromEpoch(today.timestamp - 86400);
        const last_week = DateTime.fromEpoch(yesterday.timestamp - 86400 * 7);

        var groups = std.ArrayList(Template.Context).init(ctx.alloc);

        var todays = std.ArrayList(Template.Context).init(ctx.alloc);
        var yesterdays = std.ArrayList(Template.Context).init(ctx.alloc);
        var last_weeks = std.ArrayList(Template.Context).init(ctx.alloc);
        var last_months = std.ArrayList(Template.Context).init(ctx.alloc);

        for (scribe_list.items) |each| {
            if (today.timestamp < each.date.timestamp) {
                try todays.append(try each.toContext(ctx.alloc));
            } else if (yesterday.timestamp < each.date.timestamp) {
                try yesterdays.append(try each.toContext(ctx.alloc));
            } else if (last_week.timestamp < each.date.timestamp) {
                try last_weeks.append(try each.toContext(ctx.alloc));
            } else {
                try last_months.append(try each.toContext(ctx.alloc));
            }
        }

        var today_grp = Template.Context.init(ctx.alloc);
        try today_grp.put("Group", "Today");
        if (todays.items.len > 1) {
            try today_grp.put("Lead", try std.fmt.allocPrint(
                ctx.alloc,
                "{} commits today",
                .{todays.items.len},
            ));
        }

        try today_grp.putBlock("Rows", todays.items);
        try groups.append(today_grp);
        var yesterday_grp = Template.Context.init(ctx.alloc);
        try yesterday_grp.put("Group", "Yesterday");
        if (yesterdays.items.len > 1) {
            try yesterday_grp.put("Lead", try std.fmt.allocPrint(
                ctx.alloc,
                "{} commits yesterday",
                .{yesterdays.items.len},
            ));
        }
        try yesterday_grp.putBlock("Rows", yesterdays.items);
        try groups.append(yesterday_grp);
        var last_weeks_grp = Template.Context.init(ctx.alloc);
        try last_weeks_grp.put("Group", "Last Week");
        try last_weeks_grp.putBlock("Rows", last_weeks.items);
        try groups.append(last_weeks_grp);
        var last_months_grp = Template.Context.init(ctx.alloc);
        try last_months_grp.put("Group", "Last Month");
        try last_months_grp.putBlock("Rows", last_months.items);
        try groups.append(last_months_grp);

        // TODO sort by date
        try tmpl.ctx.?.putBlock("Months", groups.items);
    }

    return ctx.sendTemplate(&tmpl) catch unreachable;
}
