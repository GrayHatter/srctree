/// we might add up to 6 days to align the grid
const DISPLAY_YEARS = 1;
const HEATMAPSIZE = DISPLAY_YEARS * 366 + 6;
const HeatMapArray = [HEATMAPSIZE]u16;

const empty_heat_map: HeatMapArray = @splat(0);

const Journal = struct {
    alloc: Allocator,
    email: []const u8,
    repos: []JRepo,
    hits: HeatMapArray,
    list: ArrayList(Scribe.Commit),

    pub const JRepo = struct {
        name: []const u8,
        sha: Git.SHA,
    };

    pub fn init(a: Allocator, email: []const u8) !*Journal {
        const j = try a.create(Journal);

        j.* = .{
            .alloc = a,
            .email = try a.dupe(email),
            .repos = &.{},
            .hits = @splat(0),
            .list = .{},
        };

        return j;
    }

    pub fn raze(j: *Journal) void {
        j.alloc.free(j.email);
        j.list.deinit(j.alloc);
        j.alloc.destroy(j);
    }

    pub fn build(
        a: Allocator,
        list: *ArrayList(Scribe.Commit),
        email: ?[]const u8,
        name: []const u8,
        repo: *const Git.Repo,
    ) !void {
        var lseen = std.BufSet.init(a);
        const until = (DateTime.fromEpoch(DateTime.now().timestamp - DAY * 90)).timestamp;
        var commit = try repo.headCommit(a);

        while (true) {
            if (lseen.contains(commit.sha.bin[0..])) break;
            var commit_time = commit.author.timestamp;
            if (DateTime.Tz.fromStr(commit.author.tzstr) catch null) |tzs| {
                commit_time += tzs.seconds;
            }
            if (commit_time < until) break;
            if (std.mem.eql(u8, email.?, commit.author.email)) {
                const ws = " \t\n";
                try list.append(a, .{
                    .name = try abx.Html.cleanAlloc(a, trim(u8, commit.author.name, ws)),
                    .title = try abx.Html.cleanAlloc(a, trim(u8, commit.title, ws)),
                    .body = if (commit.body.len > 0)
                        try Verse.abx.Html.cleanAlloc(a, trim(u8, commit.body, ws))
                    else
                        null,
                    .date = DateTime.fromEpoch(commit_time),
                    .sha = commit.sha,
                    .repo = try a.dupe(u8, name),
                });
            }

            commit = commit.toParent(a, 0, repo) catch |err| switch (err) {
                error.NoParent => break,
                else => |e| return e,
            };
        }
    }

    pub fn buildCommitList(
        a: Allocator,
        seen: *std.BufSet,
        until: i64,
        email: []const u8,
        rname: []const u8,
        repo: *const Git.Repo,
    ) !*const HeatMapArray {
        if (email.len < 5) return &empty_heat_map;

        // TODO return empty hits here
        const commit = repo.headCommit(a) catch |err| {
            std.debug.print("Error building commit list on repo {s} because {}\n", .{
                rname, err,
            });
            return &empty_heat_map;
        };

        const email_gop = try cached_emails.getOrPut(email);
        if (!email_gop.found_existing) {
            email_gop.key_ptr.* = try cached_emails.allocator.dupe(u8, email);
            email_gop.value_ptr.* = CachedRepo.init(cached_emails.allocator);
        }

        const repo_gop = try email_gop.value_ptr.*.getOrPut(rname);
        var heatmap: *HeatMap = repo_gop.value_ptr;

        var hits: *HeatMapArray = &heatmap.hits;

        if (!repo_gop.found_existing) {
            repo_gop.key_ptr.* = try cached_emails.allocator.dupe(u8, rname);
            @memset(hits[0..], 0);
        }

        if (!eql(u8, heatmap.shahex[0..], commit.sha.hex()[0..])) {
            heatmap.shahex = commit.sha.hex();
            @memset(hits[0..], 0);
            try countCommits(a, hits, seen, until, commit, repo, email);
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
                if (DateTime.Tz.fromStr(commit.author.tzstr) catch null) |tzs| {
                    commit_time += tzs.seconds;
                }

                const day_off: usize = @abs(@divFloor(commit_time - until, DAY));
                if (day_off < hits.len) hits[day_off] += 1;
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
        body: ?[]const u8,
        date: DateTime,
        sha: Git.SHA,

        pub fn toTemplate(self: Commit, a: Allocator) !S.JournalRows {
            const shahex = try a.dupe(u8, self.sha.hex()[0..]);

            const continuation = "...";
            const title_max = 80;

            // TODO is this sanitation safe?
            const title = try a.dupe(u8, self.title[0..@min(title_max, self.title.len)]);
            if (self.title.len >= title_max) {
                title[title_max - 3 .. title_max].* = continuation.*;
            }

            return .{
                .repo = self.repo,
                .body = self.body,
                .title = title,
                .cmt_line_src = .{
                    .pre = "in ",
                    .link_root = "/repo/",
                    .link_target = self.repo,
                    .name = self.repo,
                },
                .day = try allocPrint(a, "{f}", .{std.fmt.alt(self.date, .fmtYMD)}),
                .weekday = self.date.weekdaySlice(),
                .time = try allocPrint(a, "{f}", .{std.fmt.alt(self.date, .fmtTime)}),
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
    var nowish = DateTime.now();
    var email: []const u8 = "";
    var tz_offset: ?i17 = null;
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
                if (DateTime.Tz.fromStr(ts) catch @as(?DateTime.Tz, .{ .seconds = 0 })) |tzs| {
                    tz_offset = tzs.seconds;
                    nowish = DateTime.fromEpoch(nowish.timestamp + tzs.seconds);
                }
            }
        }
    }
    var date = nowish.timeTruncate();
    date = .fromEpoch(date.timestamp + DAY - DISPLAY_YEARS * YEAR);
    while (date.weekday != 0) {
        date = .fromEpoch(date.timestamp - DAY);
    }
    const start_date = date.timestamp;

    var seen = std.BufSet.init(ctx.alloc);
    var repo_count: usize = 0;

    var scribe_list: ArrayList(Scribe.Commit) = .{};

    var count_all: HeatMapArray = .{0} ** HEATMAPSIZE;

    var all_repos = repos.allRepoIterator(.public) catch return error.Unknown;
    while (all_repos.next() catch return error.Unknown) |input| {
        var repo = input;
        repo.loadData(ctx.alloc) catch {
            log.err("unable to load data for repo {s}", .{all_repos.current_name.?});
            continue;
        };
        defer repo.raze();
        const count_repo = Journal.buildCommitList(
            ctx.alloc,
            &seen,
            start_date,
            email,
            all_repos.current_name.?,
            &repo,
        ) catch {
            log.err("unable to build the commit list for repo {s}", .{all_repos.current_name.?});
            continue;
        };
        Journal.build(
            ctx.alloc,
            &scribe_list,
            email,
            all_repos.current_name.?,
            &repo,
        ) catch {
            log.err("unable to build journal for repo {s}", .{all_repos.current_name.?});
            continue;
        };
        repo_count +|= 1;
        for (&count_all, count_repo) |*a, r| a.* += r;
    }

    var tcount: u16 = 0;
    for (count_all) |h| tcount +|= h;

    var printed_month: usize = (@as(usize, @intFromEnum(date.month)) + 10) % 12;
    var day_idx: usize = 0;
    var streak: usize = 0;
    var committed_today: bool = false;
    const weeks = HEATMAPSIZE / 7;
    const flex_weeks: []S.FlexWeeks = try ctx.alloc.alloc(S.FlexWeeks, weeks);
    for (flex_weeks) |*flex_week| {
        flex_week.month = "&nbsp;";
        if ((printed_month % 12) != @intFromEnum(date.month) - 1) {
            const next_week = DateTime.fromEpoch(date.timestamp + WEEK);
            printed_month += 1;
            if ((printed_month % 12) != @intFromEnum(next_week.month) - 1) {} else {
                flex_week.month = DateTime.Names.Month[printed_month % 12 + 1][0..3];
            }
        }

        for (&flex_week.days) |*m| {
            defer date = DateTime.fromEpoch(date.timestamp + DAY);
            defer day_idx += 1;
            const count = 16 - @clz(count_all[day_idx]);
            const future_date = date.timestamp > nowish.timestamp;
            if (!future_date) {
                if (count > 0) {
                    streak +|= 1;
                    committed_today = true;
                } else if (date.timestamp + 86400 < nowish.timestamp) {
                    streak = 0;
                } else {
                    committed_today = false;
                }
            }
            m.class = if (future_date)
                " day-hide"
            else switch (count) {
                0 => "",
                1 => " day-commits day-pwr-1",
                2 => " day-commits day-pwr-2",
                3 => " day-commits day-pwr-3",
                4 => " day-commits day-pwr-4",
                5 => " day-commits day-pwr-5",
                else => " day-commits day-pwr-max",
            };

            m.title = try std.fmt.allocPrint(
                ctx.alloc,
                "{} commits on {f}",
                .{ count_all[day_idx], date.timeTruncate() },
            );
        }
    }

    const current_streak = switch (streak) {
        0 => "One Day? Or Day One!",
        1 => "Day One!",
        else => try std.fmt.allocPrint(ctx.alloc, "{} Days{s}", .{
            streak,
            if (!committed_today) "?" else "",
        }),
    };

    std.sort.pdq(Scribe.Commit, scribe_list.items, {}, Scribe.sorted);

    var scribe_blocks = try std.ArrayListUnmanaged(Template.Structs.Months).initCapacity(ctx.alloc, 6);

    const DefaultBlocks = struct {
        todays: std.ArrayListUnmanaged(S.JournalRows) = .{},
        yesterdays: std.ArrayListUnmanaged(S.JournalRows) = .{},
        last_weeks: std.ArrayListUnmanaged(S.JournalRows) = .{},
        last_months: std.ArrayListUnmanaged(S.JournalRows) = .{},
    };

    {
        const today = if (tz_offset) |tz|
            DateTime.fromEpoch(DateTime.now().timestamp + tz).timeTruncate()
        else
            DateTime.today();
        const yesterday = DateTime.fromEpoch(today.timestamp - 86400);
        const last_week = DateTime.fromEpoch(yesterday.timestamp - 86400 * 7);

        var blocks: DefaultBlocks = .{};
        for (scribe_list.items) |each| {
            if (today.timestamp < each.date.timestamp) {
                try blocks.todays.append(ctx.alloc, try each.toTemplate(ctx.alloc));
            } else if (yesterday.timestamp < each.date.timestamp) {
                try blocks.yesterdays.append(ctx.alloc, try each.toTemplate(ctx.alloc));
            } else if (last_week.timestamp < each.date.timestamp) {
                try blocks.last_weeks.append(ctx.alloc, try each.toTemplate(ctx.alloc));
            } else {
                try blocks.last_months.append(ctx.alloc, try each.toTemplate(ctx.alloc));
            }
        }

        scribe_blocks.appendAssumeCapacity(.{
            .group = "Today",
            .lead = try allocPrint(ctx.alloc, "{} commits today", .{blocks.todays.items.len}),
            .journal_rows = blocks.todays.items,
        });

        scribe_blocks.appendAssumeCapacity(.{
            .group = "Yesterday",
            .lead = try allocPrint(ctx.alloc, "{} commits yesterday", .{blocks.yesterdays.items.len}),
            .journal_rows = blocks.yesterdays.items,
        });

        scribe_blocks.appendAssumeCapacity(.{
            .group = "Last Week",
            .lead = try allocPrint(ctx.alloc, "{} commits last week", .{blocks.last_weeks.items.len}),
            .journal_rows = blocks.last_weeks.items,
        });

        scribe_blocks.appendAssumeCapacity(.{
            .group = "Last Month",
            .lead = try allocPrint(ctx.alloc, "{} commits last month", .{blocks.last_months.items.len}),
            .journal_rows = blocks.last_months.items,
        });
    }

    const page = UserCommitsPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml).?.*,
        .total_hits = try allocPrint(ctx.alloc, "{}", .{tcount}),
        .flex_weeks = flex_weeks,
        .checked_repos = try allocPrint(ctx.alloc, "{}", .{repo_count}),
        .current_streak = current_streak,
        .months = scribe_blocks.items,
    });

    return try ctx.sendPage(page);
}

const std = @import("std");
const eql = std.mem.eql;
const trim = std.mem.trim;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const allocPrint = std.fmt.allocPrint;
const log = std.log;

const DateTime = @import("../datetime.zig");
const Git = @import("../git.zig");
const repos = @import("../repos.zig");

const global_config = &@import("../main.zig").global_config.config;

const Verse = @import("verse");
const abx = Verse.abx;
const Template = Verse.template;
const DOM = Verse.template.html.DOM;
const HTML = Verse.template.html;
const S = Template.Structs;

const Route = Verse.Router;
const Error = Route.Error;
