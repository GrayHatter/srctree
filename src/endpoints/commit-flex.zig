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
    email: []const u8,
    now: DateTime,
    today: i96,
    repos: ArrayList(JRepo),
    heatmap_until: i96,
    scribe_until: i96,
    hits: HeatMapArray,
    total_count: usize,
    streak: usize,
    streak_last: ?i96,
    scribe: ArrayList(Scribe.Commit),

    pub const JRepo = struct {
        name: []const u8,
        repo: Git.Repo,
        iterator: Git.Commit.Commiterator,
        next_ts: i96 = 0,
    };

    const max_depth = 5000;

    pub fn init(email: []const u8, now: DateTime, until: i96, a: Allocator) !*Journal {
        const j = try a.create(Journal);

        const scribe_size = 90;
        const today = b: {
            var today = now;
            today.truncateTime();
            break :b today.timestamp;
        };
        j.* = .{
            .email = try a.dupe(u8, email),
            .now = now,
            .today = today,
            .repos = .empty,
            .heatmap_until = until,
            .scribe_until = (DateTime.fromEpoch(today - DAY * scribe_size)).timestamp,
            .hits = @splat(0),
            .total_count = 0,
            .streak = 0,
            .streak_last = null,
            .scribe = .empty,
        };

        return j;
    }

    pub fn raze(j: *Journal, a: Allocator, io: Io) void {
        a.free(j.email);
        for (j.repos.items) |*repo| {
            repo.iterator.raze(a);
            repo.repo.raze(a, io);
            a.free(repo.name);
        }
        j.repos.deinit(a);
        j.scribe.deinit(a);
        a.destroy(j);
    }

    pub fn addRepo(j: *Journal, repo: Repo, a: Allocator) !void {
        try j.repos.ensureUnusedCapacity(a, 2);
        j.repos.appendAssumeCapacity(.{
            .name = try a.dupe(u8, repo.name orelse ""),
            .repo = repo.git,
            // WARN &bug
            .iterator = .init(undefined, .chronological, &repo.git),
        });
    }

    pub fn build(j: *Journal, a: Allocator, io: Io) !void {
        for (j.repos.items) |*repo| {
            const head = repo.repo.HEAD(a, io) catch |err| switch (err) {
                error.RefMissing => continue,
                else => return error.ServerFault,
            };
            repo.iterator = .init(head, .chronological, &repo.repo);
            j.buildScribe(repo, a, io) catch |err| switch (err) {
                error.RefMissing => {
                    log.debug("Error building commit list for repo {s} (new repo?)", .{repo.name});
                    continue;
                },
                else => {
                    log.warn("unable to build the commit list for repo {s} [error {}]", .{ repo.name, err });
                    continue;
                },
            };
            j.cachedHeatMap(repo, a, io) catch |err| {
                log.warn("unable to build journal for repo {s} [error {}]", .{ repo.name, err });
            };
            // TODO fix this
            repo.iterator.raze(a);
            repo.iterator = .init(head, .chronological, &repo.repo);
        }
        _ = try j.buildStreak(a, io);
    }

    fn buildScribe(j: *Journal, jrepo: *JRepo, a: Allocator, io: Io) !void {
        const until = j.scribe_until;
        var head: ?Git.Commit = try jrepo.repo.HEAD(a, io);
        var itr: Git.Commit.Commiterator = .init(head.?, .chronological, &jrepo.repo);
        while (head) |commit| : (head = itr.next(a, io) catch null) {
            const commit_time: i96 = (try DateTime.fromActor(commit.author)).tzAdjusted();
            if (commit_time < until) break;
            if (eql(u8, j.email, commit.author.email)) {
                const ws = " \t\n";
                try j.scribe.append(a, .{
                    .name = try a.dupe(u8, trim(u8, commit.author.name, ws)),
                    .title = try a.dupe(u8, trim(u8, commit.title, ws)),
                    .body = try a.dupe(u8, trim(u8, commit.body, ws)),
                    .date = .fromEpoch(commit_time),
                    .sha = commit.sha,
                    .repo = jrepo.name,
                });
            }
            commit.raze(a);
        }
    }

    pub fn cachedHeatMap(j: *Journal, jrepo: *JRepo, a: Allocator, io: Io) !void {
        if (j.email.len < 5) return;

        // TODO return empty hits here
        const commit = jrepo.repo.HEAD(a, io) catch |err| switch (err) {
            // We assume the repo is actually just new/empty
            error.RefMissing => {
                log.debug("Error building commit list for repo {s} (new repo?)", .{jrepo.name});
                return;
            },
            else => {
                log.warn("Error building commit list on repo {s} because {}", .{ jrepo.name, err });
                return;
            },
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
            heatmap.sha = .zeros;
        }

        if (j.now.timestamp > heatmap.expires or !commit.sha.eql(heatmap.sha)) {
            heatmap.sha = commit.sha;
            heatmap.expires = j.now.timestamp + 3600;
            @memset(&heatmap.hits, 0);
            try j.buildHeatMap(jrepo, &heatmap.hits, j.heatmap_until, a, io);
        }

        for (&j.hits, heatmap.hits) |*dst, src| dst.* += src;

        return;
    }

    fn buildHeatMap(
        j: *Journal,
        jrepo: *JRepo,
        hits: *HeatMapArray,
        until: i96,
        a: Allocator,
        io: Io,
    ) !void {
        var misscount: usize = 0;
        var head: ?Git.Commit = try jrepo.repo.HEAD(a, io);
        var itr: Git.Commit.Commiterator = .init(head.?, .chronological, &jrepo.repo);
        while (head) |commit| : (head = itr.next(a, io) catch null) {
            if (@max(commit.author.timestamp, commit.committer.timestamp) < until)
                return;

            if (eql(u8, j.email, commit.author.email)) {
                const commit_time: i96 = (try DateTime.fromActor(commit.author)).tzAdjusted();

                const commit_offset: i96 = commit_time - until;
                const day_off: usize = @intCast(@abs(@divFloor(commit_offset, DAY)));
                if (day_off < hits.len) {
                    hits[day_off] += 1;
                    j.total_count += 1;
                }
            } else misscount += 1;
            commit.raze(a);
            if (misscount > 1000) return;
        }
    }

    fn buildStreak(j: *Journal, a: Allocator, io: Io) !usize {
        const now = j.today;
        j.streak_last = now - DAY * 2;

        for (j.repos.items) |*repo| {
            const head = try repo.repo.HEAD(a, io);
            defer head.raze(a);
            repo.iterator = .init(head, .chronological, &repo.repo);
            repo.next_ts = repo.iterator.now;
        }

        var last_ts: i96 = now;
        streak: while (j.streak_last != null) {
            last_ts = last_ts - DAY;
            log.debug("searching for day {: >9} {: >14} {: >15}", .{
                @divFloor(now - last_ts, DAY), now - last_ts, last_ts,
            });
            for (j.repos.items, 0..) |*repo, i| {
                if (repo.iterator.hold.items.len == 0) continue;
                const too_early = repo.next_ts < last_ts - DAY;
                const early = if (too_early) "early" else "hit";
                log.debug("searching repo {s: <24} [{s: ^5}] {} ({} commits left) ", .{
                    repo.name, early, repo.next_ts, repo.iterator.hold.items.len,
                });
                if (too_early) continue;

                if (j.repoStreak(repo, last_ts, a, io) catch |err| {
                    log.err("unable to build the streak list for repo {s} [{}]", .{ repo.name, err });
                    repo.iterator.raze(a);
                    continue;
                }) {
                    log.debug("        hit    {s: <24}", .{repo.name});
                    j.streak += 1;
                    if (i > 5) {
                        j.repos.insertAssumeCapacity(0, repo.*);
                        _ = j.repos.swapRemove(i + 1);
                    }
                    continue :streak;
                }
            } else j.streak_last = null;
        }
        log.debug("streak done {}", .{j.streak});
        return j.streak;
    }

    fn repoStreak(j: *Journal, jrepo: *JRepo, before: i96, a: Allocator, io: Io) !bool {
        const after = before - DAY;
        if (jrepo.iterator.hold.items.len == 0) unreachable;
        const head_time = try DateTime.fromActorAdj(jrepo.iterator.head.author);
        if (head_time < after) return false;

        var search_count: usize = 0;
        for (jrepo.iterator.hold.items) |item| {
            log.err("count {}", .{search_count});
            const commit_ts = try DateTime.fromActorAdj(item.author);
            if (commit_ts >= after and commit_ts <= before) {
                var current = try jrepo.iterator.next(a, io) orelse unreachable;
                defer current.raze(a);
                var current_ts = (try DateTime.fromActor(current.author)).tzAdjusted();
                while (current_ts > before) {
                    current = try jrepo.iterator.next(a, io) orelse return false;
                    current_ts = (try DateTime.fromActor(current.author)).tzAdjusted();
                }
                if (search_count > max_depth) return false;
                search_count += 1;
                if (current_ts >= after) {
                    if (!eql(u8, j.email, item.author.email)) continue;
                    j.streak_last = current_ts;
                    return true;
                }
                return false;
            }
        }
        return false;
    }
};

const Scribe = struct {
    thing: Option,

    const Commit = struct {
        name: []const u8,
        repo: []const u8,
        title: []const u8,
        body: []const u8,
        date: DateTime,
        sha: Git.Sha,

        pub fn toTemplate(self: Commit, a: Allocator) !S.UserCommitsHtml.Months.JournalRows {
            const shahex = try self.sha.text().dupe(a);

            const continuation = "...";
            const title_max = 80;

            // TODO is this sanitation safe?
            const title = try a.dupe(u8, self.title[0..@min(title_max, self.title.len)]);
            if (self.title.len >= title_max) {
                title[title_max - 3 .. title_max].* = continuation.*;
            }

            return .{
                .repo = .abx(self.repo),
                .body = .abx(self.body),
                .title = .abx(title),
                .cmt_line_src = .{
                    .pre = .safe("in "),
                    .link_root = .safe("/repo/"),
                    .link_target = .abx(self.repo),
                    .name = .abx(self.repo),
                },
                .day = .safe(try a.print("{f}", .{std.fmt.alt(self.date, .fmtYMD)})),
                .weekday = .safe(self.date.weekdaySlice()),
                .time = .safe(try a.print("{f}", .{std.fmt.alt(self.date, .fmtTime)})),
                .sha = .safe(shahex[0..8]),
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
    sha: Git.Sha,
    expires: i96,
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

const UserCommitsPage = T.PageData("user_commits.html");

const CommitFlexReq = struct {
    user: ?[]const u8,
};

pub fn commitFlex(ctx: *Frame) Error!void {
    var nowish = DateTime.now(ctx.io);
    var email: []const u8 = "";
    var tz_offset: ?i96 = null;
    const reqd = ctx.request.data.query.validate(CommitFlexReq) catch CommitFlexReq{ .user = null };

    if (reqd.user) |u| {
        email = u;
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
    var start_date = nowish;
    start_date.truncateTime();
    start_date.add(.secs(DAY));
    start_date.sub(.secs(DISPLAY_YEARS * YEAR));
    start_date.sub(.days(7));
    while (start_date.weekday != 0) {
        start_date = .fromEpoch(start_date.timestamp - DAY);
    }

    var repo_count: usize = 0;
    const journal: *Journal = try .init(
        email,
        nowish,
        start_date.timestamp,
        ctx.alloc,
    );
    defer journal.raze(ctx.alloc, ctx.io);

    var all_repos = Repo.iterateAll(.public_only, ctx.io) catch return error.Unknown;
    while (all_repos.next(ctx.io) catch |err| switch (err) {
        error.NotAGitRepo => brk: {
            log.warn("'{s}' is not a git repo.", .{
                all_repos.current_name orelse "[null repo name]",
            });
            break :brk all_repos.next(ctx.io) catch return error.ServerFault;
        },
        else => {
            log.err("unable to itrate repos {} stuck on {s}", .{
                err, all_repos.current_name orelse "[null repo name]",
            });
            return error.Unknown;
        },
    }) |input| {
        var repo = input;
        repo.git.loadData(ctx.alloc, ctx.io) catch {
            log.err("unable to load data for repo {s}", .{all_repos.current_name.?});
            continue;
        };
        errdefer repo.raze(ctx.alloc, ctx.io);
        if (repo.git.config.?.srctree) |st| if (st.heatmapexcluded orelse false) {
            repo.raze(ctx.alloc, ctx.io);
            continue;
        };
        try journal.addRepo(repo, ctx.alloc);
        repo_count +|= 1;
    }

    journal.build(ctx.alloc, ctx.io) catch |err| log.err("build failed {}", .{err});
    var tcount: u16 = 0;
    for (journal.hits) |h| tcount +|= h;

    var day_idx: usize = 0;
    var streak: usize = 0;
    var committed_today: bool = false;
    const weeks = HEATMAPSIZE / 7;
    const flex_weeks: []S.UserCommitsHtml.FlexWeeks =
        try ctx.alloc.alloc(S.UserCommitsHtml.FlexWeeks, weeks);

    var date = start_date;
    for (flex_weeks) |*flex_week| {
        const this_week = date;
        const last_week: DateTime = .fromEpoch(date.timestamp - WEEK);
        flex_week.month = .safe(if (last_week.month != this_week.month or
            date.timestamp == start_date.timestamp)
            this_week.monthSlice()[0..3]
        else
            "&nbsp;");

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
            m.class = .safe(if (date_is_future)
                " day-hide"
            else switch (count) {
                0 => "",
                1 => " day-commits day-pwr-1",
                2 => " day-commits day-pwr-2",
                3 => " day-commits day-pwr-3",
                4 => " day-commits day-pwr-4",
                5 => " day-commits day-pwr-5",
                else => " day-commits day-pwr-max",
            });

            var dt = date;
            dt.truncateTime();
            m.title = .safe(try ctx.alloc.print("{} commits on {f}", .{ journal.hits[day_idx], dt }));
        }
    }

    const current_streak = switch (streak) {
        0 => "One Day? Or Day One!",
        1 => "Day One!",
        else => try ctx.alloc.print("{} Days{s}", .{
            @max(streak, journal.streak + @as(usize, if (committed_today) 1 else 0)),
            if (!committed_today) "?" else "",
        }),
    };

    std.sort.pdq(Scribe.Commit, journal.scribe.items, {}, Scribe.sorted);

    var scribe_blocks = try ArrayList(S.UserCommitsHtml.Months).initCapacity(ctx.alloc, 6);

    const DefaultBlocks = struct {
        todays: ArrayList(JournalRows) = .empty,
        yesterdays: ArrayList(JournalRows) = .empty,
        last_weeks: ArrayList(JournalRows) = .empty,
        last_months: ArrayList(JournalRows) = .empty,
    };

    {
        var today: DateTime = if (tz_offset) |tz|
            DateTime.fromEpoch(DateTime.now(ctx.io).timestamp + tz)
        else
            DateTime.today(ctx.io);
        today.truncateTime();
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
            .group = .safe("Today"),
            .lead = .safe(try ctx.alloc.print("{} commits today", .{blocks.todays.items.len})),
            .journal_rows = blocks.todays.items,
        });

        scribe_blocks.appendAssumeCapacity(.{
            .group = .safe("Yesterday"),
            .lead = .safe(try ctx.alloc.print("{} commits yesterday", .{blocks.yesterdays.items.len})),
            .journal_rows = blocks.yesterdays.items,
        });

        scribe_blocks.appendAssumeCapacity(.{
            .group = .safe("Last Week"),
            .lead = .safe(try ctx.alloc.print("{} commits last week", .{blocks.last_weeks.items.len})),
            .journal_rows = blocks.last_weeks.items,
        });

        scribe_blocks.appendAssumeCapacity(.{
            .group = .safe("Last Month"),
            .lead = .safe(try ctx.alloc.print("{} commits last month", .{blocks.last_months.items.len})),
            .journal_rows = blocks.last_months.items,
        });
    }

    const page = UserCommitsPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.template_data.get(S.BodyHeaderHtml).?.*,
        .total_hits = .safe(try ctx.alloc.print("{}", .{tcount})),
        .flex_weeks = flex_weeks,
        .checked_repos = .safe(try ctx.alloc.print("{}", .{repo_count})),
        .current_streak = .safe(current_streak),
        .months = scribe_blocks.items,
    });

    return try ctx.sendPage(page);
}

const std = @import("std");
const Io = std.Io;
const eql = std.mem.eql;
const trim = std.mem.trim;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const log = std.log.scoped(.commit_flex);

const DateTime = @import("../datetime.zig");
const Git = @import("../git.zig");
const Repo = @import("../Repo.zig");

const global_config = &@import("../Config.zig").global;

const verse = @import("verse");
const Frame = verse.Frame;
const abx = verse.Antibiotic;
const T = verse.template;
const DOM = verse.template.html.DOM;
const HTML = verse.template.html;
const S = T.Structs;
const JournalRows = S.UserCommitsHtml.Months.JournalRows;

const Route = verse.Router;
const Error = Route.Error;
const debug_mode: bool = @import("builtin").mode == .debug;
