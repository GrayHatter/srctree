const Journal = struct {
    alloc: Allocator,
    email: []const u8,
    repos: []JRepo,
    hits: HeatMapArray,
    list: std.ArrayList(Scribe.Commit),

    pub const JRepo = struct {
        name: []const u8,
        sha: Git.Sha,
    };

    pub fn init(a: Allocator, email: []const u8) !*Journal {
        const j = try a.create(Journal);

        j.* = .{
            .alloc = a,
            .email = try a.dupe(email),
            .repos = &[0].{},
            .hits = .{0} ** (366 + 6),
            .list = std.ArrayList(Scribe.Commit).init(a),
        };

        return j;
    }

    pub fn raze(j: *Journal) void {
        j.alloc.free(j.email);
        j.list.deinit();
        j.alloc.destroy(j);
    }

    pub fn build(
        a: Allocator,
        list: *std.ArrayList(Scribe.Commit),
        email: ?[]const u8,
        gitdir: []const u8,
    ) !void {
        const repo_dir = try std.fs.cwd().openDir(gitdir, .{});
        var repo = try Git.Repo.init(repo_dir);
        try repo.loadData(a);
        defer repo.raze();

        var lseen = std.BufSet.init(a);
        const until = (DateTime.fromEpoch(DateTime.now().timestamp - DAY * 90)).timestamp;
        var commit = try repo.headCommit(a);

        while (true) {
            if (lseen.contains(commit.sha.bin[0..])) break;
            var commit_time = commit.author.timestamp;
            if (DateTime.tzToSec(commit.author.tzstr) catch @as(?i32, 0)) |tzs| {
                commit_time += tzs;
            }
            if (commit_time < until) break;
            if (std.mem.eql(u8, email.?, commit.author.email)) {
                try list.append(.{
                    .name = try Bleach.Html.sanitizeAlloc(a, commit.author.name),
                    .title = try Bleach.Html.sanitizeAlloc(a, commit.title),
                    .date = DateTime.fromEpoch(commit_time),
                    .sha = commit.sha,
                    .repo = try a.dupe(u8, gitdir[8..]),
                });
            }

            commit = commit.toParent(a, 0, &repo) catch |err| switch (err) {
                error.NoParent => break,
                else => |e| return e,
            };
        }
    }

    pub fn buildCommitList(
        a: Allocator,
        seen: *std.BufSet,
        until: i64,
        gitdir: []const u8,
        email: []const u8,
    ) !*HeatMapArray {
        const repo_dir = try std.fs.cwd().openDir(gitdir, .{});
        var repo = try Git.Repo.init(repo_dir);
        try repo.loadData(a);
        defer repo.raze();

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

        if (!eql(u8, heatmap.shahex[0..], commit.sha.hex[0..])) {
            heatmap.shahex = commit.sha.hex;
            @memset(hits[0..], 0);
            try countCommits(a, hits, seen, until, commit, &repo, email);
        }

        return hits;
    }

    pub fn countCommits(
        a: Allocator,
        hits: *HeatMapArray,
        seen: *std.BufSet,
        until: i64,
        root_cmt: Git.Commit,
        repo: *const Git.Repo,
        email: []const u8,
    ) !void {
        var commit = root_cmt;
        while (true) {
            const search_time = @max(commit.author.timestamp, commit.committer.timestamp);
            if (search_time < until) return;
            if (seen.contains(commit.sha.bin[0..])) return;

            seen.insert(commit.sha.bin[0..]) catch unreachable;
            if (eql(u8, email, commit.author.email)) {
                var commit_time = commit.author.timestamp;
                if (DateTime.tzToSec(commit.author.tzstr) catch @as(?i32, 0)) |tzs| {
                    commit_time += tzs;
                }

                const day_off: usize = @abs(@divFloor(commit_time - until, DAY));
                hits[day_off] += 1;
            }
            for (commit.parent[1..], 1..) |par, pidx| {
                if (par != null) {
                    const parent = try commit.toParent(a, @truncate(pidx), repo);
                    try countCommits(a, hits, seen, until, parent, repo, email);
                }
            }
            commit = commit.toParent(a, 0, repo) catch |err| switch (err) {
                error.NoParent => break,
                else => |e| return e,
            };
        }
    }
};

const Scribe = struct {
    thing: Option,

    const Commit = struct {
        name: []const u8,
        repo: []const u8,
        title: []const u8,
        date: DateTime,
        sha: Git.SHA,

        pub fn toTemplate(self: Commit, a: Allocator) !S.JournalRows {
            const shahex = try a.dupe(u8, self.sha.hex[0..]);
            return .{
                //.name = self.name,
                .repo = self.repo,
                .title = self.title,
                .date = try allocPrint(
                    a,
                    "<span>{Y-m-d}</span><span>{day}</span><span>{time}</span>",
                    .{ self.date, self.date, self.date },
                ),
                .sha = shahex[0..8],
            };
        }
    };

    const Option = union(enum) {
        commit: Commit,
    };

    pub fn sorted(_: void, left: Commit, right: Commit) bool {
        return !lessThan({}, left, right);
    }

    fn lessThan(_: void, left: Commit, right: Commit) bool {
        if (left.date.timestamp < right.date.timestamp) return true;
        if (left.date.timestamp > right.date.timestamp) return false;
        if (left.repo.len < right.repo.len) return true;
        return false;
    }
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
    shahex: Git.SHA.Hex,
    hits: HeatMapArray,
};

pub const CachedRepo = std.StringHashMap(HeatMap);

pub const CACHED_EMAIL = std.StringHashMap(CachedRepo);
var cached_emails: CACHED_EMAIL = undefined;

pub fn initCache(a: Allocator) void {
    cached_emails = CACHED_EMAIL.init(a);
}

pub fn razeCache(a: Allocator) void {
    var itr = cached_emails.iterator();
    while (itr.next()) |next| {
        a.free(next.key_ptr.*);
        var ritr = next.value_ptr.*.iterator();
        while (ritr.next()) |rnext| {
            a.free(rnext.key_ptr.*);
        }
        next.value_ptr.*.deinit();
    }
    cached_emails.deinit();
}

const DAY = 86400;
const WEEK = DAY * 7;
const YEAR = 31_536_000;

const UserCommitsPage = Template.PageData("user_commits.html");

pub fn commitFlex(ctx: *Verse.Frame) Error!void {
    const monthAtt = HTML.Attr.class("month");

    var nowish = DateTime.now();
    var email: []const u8 = undefined;
    var tz_offset: ?i32 = null;
    var query = ctx.request.data.query.validator();
    const user = query.optionalItem("user");

    if (user) |u| {
        email = u.value;
    } else {
        if (global_config.owner) |owner| {
            if (owner.email) |c_email| {
                email = c_email;
            } else @panic("no email configured");
            if (owner.tz) |ts| {
                if (DateTime.tzToSec(ts) catch @as(?i32, 0)) |tzs| {
                    tz_offset = tzs;
                    nowish = DateTime.fromEpoch(nowish.timestamp + tzs);
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
                const count_repo = Journal.buildCommitList(ctx.alloc, &seen, until, repo, email) catch unreachable;
                Journal.build(ctx.alloc, &scribe_list, email, repo) catch {
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

    const current_streak = switch (streak) {
        0 => "One Day? Or Day One!",
        1 => "Day One!",
        else => try std.fmt.allocPrint(ctx.alloc, "{} Days{s}", .{
            streak,
            if (!committed_today) "?" else "",
        }),
    };

    const list = try ctx.alloc.alloc([]u8, flex.len);
    for (list, flex) |*l, e| l.* = try std.fmt.allocPrint(ctx.alloc, "{}", .{e});
    const flexes = try std.mem.join(ctx.alloc, "", list);

    std.sort.pdq(Scribe.Commit, scribe_list.items, {}, Scribe.sorted);

    var months = std.ArrayList(Template.Structs.Months).init(ctx.alloc);
    {
        const today = if (tz_offset) |tz|
            DateTime.fromEpoch(DateTime.now().timestamp + tz).removeTime()
        else
            DateTime.today();
        const yesterday = DateTime.fromEpoch(today.timestamp - 86400);
        const last_week = DateTime.fromEpoch(yesterday.timestamp - 86400 * 7);

        var todays = std.ArrayList(S.JournalRows).init(ctx.alloc);
        var yesterdays = std.ArrayList(S.JournalRows).init(ctx.alloc);
        var last_weeks = std.ArrayList(S.JournalRows).init(ctx.alloc);
        var last_months = std.ArrayList(S.JournalRows).init(ctx.alloc);

        for (scribe_list.items) |each| {
            if (today.timestamp < each.date.timestamp) {
                try todays.append(try each.toTemplate(ctx.alloc));
            } else if (yesterday.timestamp < each.date.timestamp) {
                try yesterdays.append(try each.toTemplate(ctx.alloc));
            } else if (last_week.timestamp < each.date.timestamp) {
                try last_weeks.append(try each.toTemplate(ctx.alloc));
            } else {
                try last_months.append(try each.toTemplate(ctx.alloc));
            }
        }

        try months.append(.{
            .group = "Today",
            .lead = try allocPrint(ctx.alloc, "{} commits today", .{todays.items.len}),
            .journal_rows = try todays.toOwnedSlice(),
        });

        try months.append(.{
            .group = "Yesterday",
            .lead = try allocPrint(ctx.alloc, "{} commits yesterday", .{yesterdays.items.len}),
            .journal_rows = try yesterdays.toOwnedSlice(),
        });

        try months.append(.{
            .group = "Last Week",
            .lead = try allocPrint(ctx.alloc, "{} commits today", .{last_weeks.items.len}),
            .journal_rows = try last_weeks.toOwnedSlice(),
        });

        try months.append(.{
            .group = "Last Month",
            .lead = try allocPrint(ctx.alloc, "{} commits last month", .{last_months.items.len}),
            .journal_rows = try last_months.toOwnedSlice(),
        });
    }

    var page = UserCommitsPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch return error.Unknown,
        .total_hits = try allocPrint(ctx.alloc, "{}", .{tcount}),
        .flexes = flexes,
        .checked_repos = try allocPrint(ctx.alloc, "{}", .{repo_count}),
        .current_streak = current_streak,
        .months = try months.toOwnedSlice(),
    });

    return try ctx.sendPage(&page);
}

const std = @import("std");
const eql = std.mem.eql;
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;

const Bleach = @import("../bleach.zig");
const DateTime = @import("../datetime.zig");
const Git = @import("../git.zig");

const global_config = &@import("../main.zig").global_config;

const Verse = @import("verse");
const Template = Verse.template;
const DOM = Verse.template.html.DOM;
const HTML = Verse.template.html;
const S = Template.Structs;

const Route = Verse.Router;
const Error = Route.Error;
