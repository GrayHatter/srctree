/// we might add up to 6 days to align the grid
const DISPLAY_YEARS = 1;
const WEEKS_PER_YEAR: f64 = 52.1429;
// Add one extra week to account for day starts/offset
const HEATMAPSIZE = DISPLAY_YEARS * @as(usize, @intFromFloat(@ceil(WEEKS_PER_YEAR + 1))) * 7;
const DAY = 86400;
const WEEK = DAY * 7;
const YEAR = DAY * 365;
const HeatMapArray = [HEATMAPSIZE]u16;

const Journal = struct {
    alloc: Allocator,
    email: []const u8,
    tz_offset: ?i17,
    repos: ArrayList(JRepo),
    heatmap_until: i64,
    scribe_until: i64,
    hits: HeatMapArray,
    total_count: usize,
    streak: usize,
    streak_last: ?i64,
    scribe: ArrayList(Scribe.Commit),

    pub const JRepo = struct {
        name: []const u8,
        repo: Git.Repo,
        bufset: std.BufSet,
        commits: ArrayList(Git.Commit),
        next_ts: i64 = 0,
    };

    pub fn init(a: Allocator, email: []const u8, until: i64, tz: ?i17) !*Journal {
        const j = try a.create(Journal);

        const scribe_size = 90;
        j.* = .{
            .alloc = a,
            .email = try a.dupe(u8, email),
            .tz_offset = tz,
            .repos = .{},
            .heatmap_until = until,
            .scribe_until = (DateTime.fromEpoch(DateTime.now().timestamp - DAY * scribe_size)).timestamp,
            .hits = @splat(0),
            .total_count = 0,
            .streak = 0,
            .streak_last = null,
            .scribe = .{},
        };

        return j;
    }

    pub fn raze(j: *Journal) void {
        j.alloc.free(j.email);
        for (j.repos.items) |repo| {
            repo.repo.raze();
            j.alloc.free(repo.name);
        }
        j.repos.deinit(j.alloc);
        j.scribe.deinit(j.alloc);
        j.alloc.destroy(j);
    }

    pub fn addRepo(j: *Journal, name: []const u8, repo: Git.Repo) !void {
        try j.repos.append(j.alloc, .{
            .name = try j.alloc.dupe(u8, name),
            .repo = repo,
            .bufset = .init(j.alloc),
            .commits = .{},
        });
    }

    pub fn build(j: *Journal) !void {
        for (j.repos.items) |*repo| {
            j.buildScribe(repo) catch |err| {
                log.err("unable to build the commit list for repo {s} [error {}]", .{ repo.name, err });
            };
            j.cachedHeatMap(repo) catch |err| {
                log.err("unable to build journal for repo {s} [error {}]", .{ repo.name, err });
            };
        }
        _ = try j.buildBestStreak();
    }

    fn buildScribe(j: *Journal, jrepo: *JRepo) !void {
        var lseen = std.BufSet.init(j.alloc);
        var commit = try jrepo.repo.headCommit(j.alloc);
        const until = j.scribe_until;

        while (true) {
            if (lseen.contains(commit.sha.bin[0..])) break;
            const commit_time: i64 = (try DateTime.fromEpochTzStr(commit.author.timestamp, commit.author.tzstr)).tzAdjusted();
            if (commit_time < until) break;
            if (std.mem.eql(u8, j.email, commit.author.email)) {
                const ws = " \t\n";
                try j.scribe.append(j.alloc, .{
                    .name = try abx.Html.cleanAlloc(j.alloc, trim(u8, commit.author.name, ws)),
                    .title = try abx.Html.cleanAlloc(j.alloc, trim(u8, commit.title, ws)),
                    .body = if (commit.body.len > 0)
                        try Verse.abx.Html.cleanAlloc(j.alloc, trim(u8, commit.body, ws))
                    else
                        null,
                    .date = DateTime.fromEpoch(commit_time),
                    .sha = commit.sha,
                    .repo = jrepo.name,
                });
            }

            commit = commit.toParent(j.alloc, 0, &jrepo.repo) catch |err| switch (err) {
                error.NoParent => break,
                else => |e| return e,
            };
        }
    }

    pub fn cachedHeatMap(j: *Journal, jrepo: *JRepo) !void {
        if (j.email.len < 5) return;

        // TODO return empty hits here
        const commit = jrepo.repo.headCommit(j.alloc) catch |err| {
            std.debug.print("Error building commit list on repo {s} because {}\n", .{
                jrepo.name, err,
            });
            return;
        };

        const email_gop = try cached_emails.getOrPut(j.email);
        if (!email_gop.found_existing) {
            email_gop.key_ptr.* = try cached_emails.allocator.dupe(u8, j.email);
            email_gop.value_ptr.* = CachedRepo.init(cached_emails.allocator);
        }

        const repo_gop = try email_gop.value_ptr.*.getOrPut(jrepo.name);
        var heatmap: *HeatMap = repo_gop.value_ptr;

        if (!repo_gop.found_existing) {
            repo_gop.key_ptr.* = try cached_emails.allocator.dupe(u8, jrepo.name);
            @memset(&heatmap.hits, 0);
            heatmap.shahex = @splat(0);
        }

        if (!eql(u8, heatmap.shahex[0..], commit.sha.hex()[0..])) {
            heatmap.shahex = commit.sha.hex();
            @memset(&heatmap.hits, 0);
            try j.buildHeatMap(jrepo, &heatmap.hits, commit, j.heatmap_until);
        }

        for (&j.hits, heatmap.hits) |*dst, src| dst.* += src;

        return;
    }

    fn buildHeatMap(j: *Journal, jrepo: *JRepo, hits: *HeatMapArray, root_cmt: Git.Commit, until: i64) !void {
        var commit = root_cmt;
        while (true) {
            if (until > @max(commit.author.timestamp, commit.committer.timestamp)) {
                return;
            }

            if (jrepo.bufset.contains(commit.sha.bin[0..])) return;
            jrepo.bufset.insert(commit.sha.bin[0..]) catch unreachable;

            if (eql(u8, j.email, commit.author.email)) {
                const commit_time: i64 = (try DateTime.fromEpochTzStr(commit.author.timestamp, commit.author.tzstr)).tzAdjusted();

                const commit_offset: isize = commit_time - until;
                const day_off: usize = @abs(@divFloor(commit_offset, DAY));
                if (day_off < hits.len) {
                    hits[day_off] += 1;
                    j.total_count += 1;
                }

                // TODO start streak count here
                //if (j.streak_last) |last| {
                //    if (last == day_off + 1) {
                //        j.streak_last = commit_time;
                //    }
                //}
            }

            for (commit.parent[1..], 1..) |parent_sha, pidx| {
                if (parent_sha) |_| {
                    const parent = try commit.toParent(j.alloc, @truncate(pidx), &jrepo.repo);
                    try j.buildHeatMap(jrepo, hits, parent, until);
                }
            }
            commit = commit.toParent(j.alloc, 0, &jrepo.repo) catch |err| switch (err) {
                error.NoParent => break,
                else => |e| return e,
            };
        }
    }

    fn buildBestStreak(j: *Journal) !void {
        const now = DateTime.today().timestamp;
        j.streak_last = now - DAY * 2;

        for (j.repos.items) |*repo| {
            try repo.commits.append(j.alloc, repo.repo.headCommit(j.alloc) catch |err| {
                std.debug.print("Error building streak list for repo {s} because {}\n", .{
                    repo.name, err,
                });
                continue;
            });
            repo.next_ts = repo.commits.items[0].author.timestamp;
        }

        //var after_ts: i64 = now + (j.tz_offset orelse 0);
        var after_ts: i64 = now - DAY;
        while (j.streak_last != null) {
            const best_day: i64 = @divFloor((now + DAY - after_ts), DAY);
            after_ts = after_ts - DAY;
            const debug_dt = DateTime.fromEpoch(after_ts);
            std.debug.print("finding {} : {} ({f})", .{ best_day, after_ts, debug_dt });
            for (j.repos.items) |*repo| {
                if (repo.commits.items.len == 0) continue;
                if (repo.next_ts < after_ts) {
                    std.debug.print("  skip {s} \n", .{repo.name});
                    continue;
                }
                //else if (repo.best_day == best_day + 1) {
                //    std.debug.print("already found streak {s}\n", .{repo.name});
                //    j.streak_last.? = last - ;
                //    j.streak += 1;
                //    break;
                //}
                std.debug.print("\n checking {s}\n", .{repo.name});
                if (j.buildBestStreakRepo(repo, after_ts) catch |err| {
                    log.err("unable to build the streak list for repo {s} [error {}]", .{ repo.name, err });
                    repo.commits.deinit(j.alloc);
                    continue;
                }) {
                    j.streak += 1;
                    std.debug.print(" found streak {s} {} {} {}\n", .{ repo.name, j.streak_last.? - after_ts, after_ts, j.streak_last.? });
                    break;
                }
            } else {
                std.debug.print("gave up \n", .{});
                j.streak_last = null;
            }
        }
    }

    pub fn findBestTime(
        a: Allocator,
        email: []const u8,
        repo: *const Git.Repo,
        commits: *ArrayList(Git.Commit),
        after: i64,
        counter: *usize,
    ) !?Git.Commit {
        for (0..commits.items.len) |i| {
            var commit = commits.items[i];
            const before = after + DAY;

            while (true) {
                counter.* += 1;
                const commit_time: i64 = (try DateTime.fromEpochTzStr(commit.author.timestamp, commit.author.tzstr)).tzAdjusted();
                std.debug.print("    {} (time) {} \n", .{ commit_time, commit_time - after });
                if (commit_time < after) {
                    return null;
                } else if (commit_time <= before) {
                    if (eql(u8, email, commit.author.email))
                        return commit;
                }
                std.debug.print("    {} (time2) {}\n", .{ commit_time, commit_time - after });

                if (commit.parent[1] != null) {
                    commits.items[i] = commit.toParent(a, 0, repo) catch return null;
                    var temp_list: ArrayList(Git.Commit) = try .initCapacity(a, 1);
                    for (commit.parent[1..], 1..) |parent_sha, pidx| {
                        if (parent_sha == null) break;
                        const parent = try commit.toParent(a, @truncate(pidx), repo);
                        try temp_list.append(a, parent);
                    }
                    const maybe: ?Git.Commit = try findBestTime(a, email, repo, &temp_list, after, counter);
                    for (temp_list.items) |itm| {
                        try commits.append(a, itm);
                    }

                    if (maybe) |cmt| return cmt;
                } else if (commit.parent[0] != null) {
                    commits.items[i] = commit.toParent(a, 0, repo) catch return null;
                    continue;
                }
                break;
            }
        }
        return null;
    }

    fn buildBestStreakRepo(j: *Journal, jrepo: *JRepo, after: i64) !bool {
        if (jrepo.commits.items.len > 0) return false;
        var counter: usize = 0;
        const commit: Git.Commit = try findBestTime(j.alloc, j.email, &jrepo.repo, &jrepo.commits, after, &counter) orelse {
            //std.debug.print("    {} (debug)\n", .{r_commit.author.timestamp - after});
            //std.debug.print("    {} (debug)\n", .{@divFloor(r_commit.author.timestamp - after, DAY)});
            for (jrepo.commits.items) |cmt| {
                const day_depth = @divFloor(cmt.author.timestamp - after, DAY);
                if (counter > 5000 or day_depth > 100 and !eql(u8, j.email, cmt.author.email)) {
                    //std.debug.print("dropping head\n", .{});
                    jrepo.commits.deinit(j.alloc);
                }
            }
            return false;
        };

        const commit_time: i64 = (try DateTime.fromEpochTzStr(
            commit.author.timestamp,
            commit.author.tzstr,
        )).tzAdjusted();
        //jrepo.head = commit;
        j.streak_last = commit_time;

        return true;
    }
};

test "best streak" {
    const alloc = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var repo = (try repos.open("srctree", .public)).?;
    try repo.loadData(a);
    defer repo.raze();
    var head: [1]Git.Commit = .{try repo.headCommit(a)};
    var list: ArrayList(Git.Commit) = .initBuffer(&head);
    const now = 1760659200;
    var counter: usize = 0;
    const best = try Journal.findBestTime(a, "_@gr.ht", &repo, &list, now - DAY - DAY, &counter);
    const best2 = try Journal.findBestTime(a, "_@gr.ht", &repo, &list, now - DAY - DAY - DAY, &counter);

    if (false) {
        std.debug.print("now ts {}\n", .{now});
        std.debug.print("head ts {}\n", .{head[0].author.timestamp});
        std.debug.print("now ts {}\n", .{best.?.author.timestamp});
        std.debug.print("now ts {}\n", .{best2.?.author.timestamp});
    }

    std.testing.expect(best != null) catch return error.SkipZigTest;
}

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
    var start_date = nowish.timeTruncate();
    start_date = .fromEpoch(start_date.timestamp + DAY - DISPLAY_YEARS * YEAR - 7 * DAY);
    while (start_date.weekday != 0) {
        start_date = .fromEpoch(start_date.timestamp - DAY);
    }

    var repo_count: usize = 0;
    const journal: *Journal = try .init(ctx.alloc, email, start_date.timestamp, tz_offset);

    var all_repos = repos.allRepoIterator(.public) catch return error.Unknown;
    while (all_repos.next() catch return error.Unknown) |input| {
        var repo = input;
        repo.loadData(ctx.alloc) catch {
            log.err("unable to load data for repo {s}", .{all_repos.current_name.?});
            continue;
        };
        errdefer repo.raze();
        try journal.addRepo(all_repos.current_name.?, repo);
        repo_count +|= 1;
    }

    try journal.build();
    var tcount: u16 = 0;
    for (journal.hits) |h| tcount +|= h;

    var printed_month: usize = (@as(usize, @intFromEnum(start_date.month)) + 10) % 12;
    var day_idx: usize = 0;
    var streak: usize = 0;
    var committed_today: bool = false;
    const weeks = HEATMAPSIZE / 7;
    const flex_weeks: []S.FlexWeeks = try ctx.alloc.alloc(S.FlexWeeks, weeks);

    var date = start_date;
    for (flex_weeks) |*flex_week| {
        flex_week.month = "&nbsp;";
        if ((printed_month % 12) != @intFromEnum(start_date.month) - 1) {
            const next_week = DateTime.fromEpoch(start_date.timestamp + WEEK);
            printed_month += 1;
            if ((printed_month % 12) != @intFromEnum(next_week.month) - 1) {} else {
                flex_week.month = DateTime.Names.Month[printed_month % 12 + 1][0..3];
            }
        }

        for (&flex_week.days) |*m| {
            defer date = DateTime.fromEpoch(date.timestamp + DAY);
            defer day_idx += 1;
            const count = 16 - @clz(journal.hits[day_idx]);
            const date_is_future = date.timestamp > nowish.timestamp;
            if (!date_is_future) {
                if (count > 0) {
                    streak +|= 1;
                    committed_today = true;
                } else if (date.timestamp + 86400 < nowish.timestamp) {
                    streak = 0;
                } else {
                    streak +|= 1;
                    committed_today = false;
                }
            }
            m.class = if (date_is_future)
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
                .{ journal.hits[day_idx], date.timeTruncate() },
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

    std.sort.pdq(Scribe.Commit, journal.scribe.items, {}, Scribe.sorted);

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
        for (journal.scribe.items) |each| {
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
