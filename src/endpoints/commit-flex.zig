const std = @import("std");

const Allocator = std.mem.Allocator;

const Bleach = @import("../bleach.zig");
const DateTime = @import("../datetime.zig");
const Git = @import("../git.zig");

const DOM = @import("../dom.zig");
const HTML = @import("../html.zig");
const Context = @import("../context.zig");
const Template = @import("../template.zig");

const Route = @import("../routes.zig");
const Error = Route.Error;

const Scribe = struct {
    const Commit = struct {
        name: []const u8,
        repo: []const u8,
        title: []const u8,
        date: DateTime,
        sha: []const u8,

        pub fn toContext(self: Commit, a: Allocator) !Template.Context {
            var jctx = Template.Context.init(a);
            try jctx.putSlice("Name", self.name);
            try jctx.putSlice("Repo", self.repo);
            try jctx.putSlice("Title", self.title);
            try jctx.putSlice("Date", try std.fmt.allocPrint(
                a,
                "<span>{Y-m-d}</span><span>{day}</span><span>{time}</span>",
                .{ self.date, self.date, self.date },
            ));
            try jctx.putSlice("ShaLong", self.sha);
            try jctx.putSlice("Sha", self.sha[0..8]);
            return jctx;
        }
    };

    const Option = union(enum) {
        commit: Commit,
    };

    thing: Option,
};

const Day = struct {
    //prev: ?*Day,
    //next: ?*Day,
    events: []Scribe,
};

/// we might add up to 6 days to align the grid
const HeatMapSize = 366 + 6;
const HeatMapArray = [HeatMapSize]u16;

pub const HeatMap = struct {
    sha: [40]u8,
    hits: HeatMapArray,
};

pub const CachedRepo = std.StringHashMap(HeatMap);

pub const CACHED_EMAIL = std.StringHashMap(CachedRepo);
var cached_emails: CACHED_EMAIL = undefined;

pub fn initCache(a: Allocator) void {
    cached_emails = CACHED_EMAIL.init(a);
}

pub fn razeCache() void {
    cached_emails.deinit();
}

fn countAll(
    a: Allocator,
    hits: *HeatMapArray,
    seen: *std.BufSet,
    until: i64,
    root_cmt: Git.Commit,
    email: []const u8,
) !*HeatMapArray {
    var commit = root_cmt;
    while (true) {
        if (seen.contains(commit.sha)) return hits;
        var commit_time = commit.author.timestamp;
        if (DateTime.tzToSec(commit.author.tzstr) catch @as(?i32, 0)) |tzs| {
            commit_time += tzs;
        }

        if (commit_time < until or commit.committer.timestamp < until) return hits;
        const day_off: usize = @abs(@divFloor(commit_time - until, DAY));
        if (std.mem.eql(u8, email, commit.author.email)) {
            hits[day_off] += 1;
        }
        for (commit.parent[1..], 1..) |par, pidx| {
            if (par) |_| {
                seen.insert(par.?) catch unreachable;
                const parent = try commit.toParent(a, @truncate(pidx));
                //defer parent.raze(a);
                _ = try countAll(a, hits, seen, until, parent, email);
            }
        }
        commit = commit.toParent(a, 0) catch |err| switch (err) {
            error.NoParent => {
                return hits;
            },
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
    var commit = try repo.headCommit(a);

    while (true) {
        if (lseen.contains(commit.sha)) break;
        var commit_time = commit.author.timestamp;
        if (DateTime.tzToSec(commit.author.tzstr) catch @as(?i32, 0)) |tzs| {
            commit_time += tzs;
        }
        if (commit_time < until) break;
        if (std.mem.eql(u8, email.?, commit.author.email)) {
            try list.append(.{
                .name = try Bleach.sanitizeAlloc(a, commit.author.name, .{}),
                .title = try Bleach.sanitizeAlloc(a, commit.title, .{}),
                .date = DateTime.fromEpoch(commit_time),
                .sha = try a.dupe(u8, commit.sha),
                .repo = try a.dupe(u8, gitdir[8..]),
            });
        }

        commit = commit.toParent(a, 0) catch |err| switch (err) {
            error.NoParent => break,
            else => |e| return e,
        };
    }
}

fn buildCommitList(a: Allocator, seen: *std.BufSet, until: i64, gitdir: []const u8, email: []const u8) !*HeatMapArray {
    const repo_dir = try std.fs.cwd().openDir(gitdir, .{});
    var repo = try Git.Repo.init(repo_dir);
    try repo.loadData(a);
    defer repo.raze(a);

    // TODO return empty hits here
    const commit = repo.headCommit(a) catch unreachable;

    const email_gop = try cached_emails.getOrPut(email);
    if (!email_gop.found_existing) {
        email_gop.key_ptr.* = try cached_emails.allocator.dupe(u8, email);
        email_gop.value_ptr.* = CachedRepo.init(cached_emails.allocator);
    }

    const repo_gop = try email_gop.value_ptr.*.getOrPut(gitdir);
    var heatmap: *HeatMap = repo_gop.value_ptr;

    var hits: *HeatMapArray = &heatmap.hits;

    if (!repo_gop.found_existing) {
        repo_gop.key_ptr.* = try cached_emails.allocator.dupe(u8, gitdir);
        @memset(hits[0..], 0);
    }

    if (!std.mem.eql(u8, heatmap.sha[0..], commit.sha[0..40])) {
        @memcpy(heatmap.sha[0..], commit.sha[0..40]);
        @memset(hits[0..], 0);
        _ = try countAll(a, hits, seen, until, commit, email);
    }

    return hits;
}

const DAY = 60 * 60 * 24;
const WEEK = DAY * 7;
const YEAR = 31_536_000;

pub fn commitFlex(ctx: *Context) Error!void {
    const monthAtt = HTML.Attr.class("month");

    var nowish = DateTime.now();
    var email: []const u8 = undefined;
    var tz_offset: ?i32 = null;
    var query = ctx.req_data.query_data.validator();
    const user = query.optional("user");

    if (user) |u| {
        email = u.value;
    } else {
        if (ctx.cfg) |ini| {
            if (ini.get("owner")) |ns| {
                if (ns.get("email")) |c_email| {
                    email = c_email;
                } else @panic("no email configured");
                if (ns.get("tz")) |ts| {
                    if (DateTime.tzToSec(ts) catch @as(?i32, 0)) |tzs| {
                        tz_offset = tzs;
                        nowish = DateTime.fromEpoch(nowish.timestamp + tzs);
                    }
                }
            }
        }
    }
    var date = nowish.removeTime();
    date = DateTime.fromEpoch(date.timestamp + DAY - YEAR);
    while (date.weekday != 0) {
        date = DateTime.fromEpoch(date.timestamp - DAY);
    }
    const until = date.timestamp;

    var seen = std.BufSet.init(ctx.alloc);
    var repo_count: usize = 0;
    var dir = std.fs.cwd().openDir("./repos", .{ .iterate = true }) catch {
        return error.Unknown;
    };

    var scribe_list = std.ArrayList(Scribe.Commit).init(ctx.alloc);

    var count_all: HeatMapArray = .{0} ** (366 + 6);

    var itr = dir.iterate();
    while (itr.next() catch return Error.Unknown) |file| {
        var buf: [1024]u8 = undefined;
        switch (file.kind) {
            .directory, .sym_link => {
                const repo = std.fmt.bufPrint(&buf, "./repos/{s}", .{file.name}) catch return Error.Unknown;
                const count_repo = buildCommitList(ctx.alloc, &seen, until, repo, email) catch unreachable;
                buildJournal(ctx.alloc, &scribe_list, email, repo) catch {
                    return error.Unknown;
                };
                repo_count +|= 1;
                for (&count_all, count_repo) |*a, r| a.* += r;
            },
            else => {},
        }
    }

    var dom = DOM.new(ctx.alloc);
    var tcount: u16 = 0;
    for (count_all) |h| tcount +|= h;

    var printed_month: usize = (date.months + 10) % 12;
    var day_offset: usize = 0;
    var streak: usize = 0;
    var committed_today: bool = false;
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
            defer day_offset += 1;
            const rows = try ctx.alloc.alloc(HTML.Attribute, 2);
            const count = 16 - @clz(count_all[day_offset]);
            const future_date = date.timestamp >= nowish.timestamp - 1;
            if (!future_date) {
                if (count > 0) {
                    streak +|= 1;
                    committed_today = true;
                } else if (date.timestamp + 86400 <= nowish.timestamp - 1) {
                    streak = 0;
                } else {
                    committed_today = false;
                }
            }
            const class = if (future_date)
                "day-hide"
            else switch (count) {
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
                        .{ count_all[day_offset], date },
                    ),
                },
            });
            m.* = HTML.div(null, rows);
        }
        dom.push(HTML.div(column, &HTML.Attr.class("col")));
    }

    const flex = dom.done();

    var tmpl = Template.find("user_commits.html");

    try ctx.putContext("CurrentStreak", .{
        .slice = switch (streak) {
            0 => "One Day? Or Day One!",
            1 => "Day One!",
            else => try std.fmt.allocPrint(ctx.alloc, "{} Days{s}", .{
                streak,
                if (!committed_today) "?" else "",
            }),
        },
    });

    try ctx.putContext("TotalHits", .{ .slice = try std.fmt.allocPrint(ctx.alloc, "{}", .{tcount}) });
    try ctx.putContext("CheckedRepos", .{ .slice = try std.fmt.allocPrint(ctx.alloc, "{}", .{repo_count}) });
    _ = ctx.addElements(ctx.alloc, "Flexes", flex) catch return Error.Unknown;

    std.sort.pdq(Scribe.Commit, scribe_list.items, {}, journalSorted);

    {
        const today = if (tz_offset) |tz|
            DateTime.fromEpoch(DateTime.now().timestamp + tz).removeTime()
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
        try today_grp.putSlice("Group", "Today");
        if (todays.items.len > 1) {
            try today_grp.putSlice("Lead", try std.fmt.allocPrint(
                ctx.alloc,
                "{} commits today",
                .{todays.items.len},
            ));
        }

        try today_grp.putBlock("Rows", todays.items);
        try groups.append(today_grp);
        var yesterday_grp = Template.Context.init(ctx.alloc);
        try yesterday_grp.putSlice("Group", "Yesterday");
        if (yesterdays.items.len > 1) {
            try yesterday_grp.putSlice("Lead", try std.fmt.allocPrint(
                ctx.alloc,
                "{} commits yesterday",
                .{yesterdays.items.len},
            ));
        }
        try yesterday_grp.putBlock("Rows", yesterdays.items);
        try groups.append(yesterday_grp);
        var last_weeks_grp = Template.Context.init(ctx.alloc);
        try last_weeks_grp.putSlice("Group", "Last Week");
        try last_weeks_grp.putBlock("Rows", last_weeks.items);
        try groups.append(last_weeks_grp);
        var last_months_grp = Template.Context.init(ctx.alloc);
        try last_months_grp.putSlice("Group", "Last Month");
        try last_months_grp.putBlock("Rows", last_months.items);
        try groups.append(last_months_grp);

        // TODO sort by date
        try ctx.putContext("Months", .{ .block = groups.items });
    }

    return ctx.sendTemplate(&tmpl) catch unreachable;
}
