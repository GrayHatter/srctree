const std = @import("std");

const Allocator = std.mem.Allocator;

const DateTime = @import("../datetime.zig");
const Endpoint = @import("../endpoint.zig");
const Git = @import("../git.zig");
const Ini = @import("../ini.zig");

const DOM = Endpoint.DOM;
const HTML = Endpoint.HTML;
const Response = Endpoint.Response;
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
        const day_off: usize = std.math.absCast(@divFloor(commit_time - until, DAY));
        if (owner_email) |email| {
            if (std.mem.eql(u8, email, commit.author.email)) {
                hits[day_off] += 1;
                //std.log.info("BAH! {}", .{commit});
            }
        } else hits[day_off] += 1;
        for (commit.parent[1..], 1..) |par, pidx| {
            if (par) |_| {
                seen.?.insert(par.?) catch return &hits;
                var parent = try commit.toParent(a, @truncate(pidx));
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
    var repo_dir = try std.fs.cwd().openDir(gitdir, .{});
    var repo = try Git.Repo.init(repo_dir);
    try repo.loadData(a);
    defer repo.raze(a);

    var commit = repo.commit(a) catch return &hits;
    return try countAll(a, until, commit);
}

const YEAR = 31_536_000;
const DAY = 60 * 60 * 24;

pub fn commitFlex(r: *Response, _: *Endpoint.Router.UriIter) Error!void {
    const day = HTML.Attr.class("day");
    const monthAtt = HTML.Attr.class("month");

    var nowish = DateTime.now();
    var date = DateTime.today();
    date = DateTime.fromEpoch(date.timestamp + DAY - YEAR) catch unreachable;
    while (date.weekday != 0) {
        date = DateTime.fromEpoch(date.timestamp - DAY) catch unreachable;
    }
    const until = date.timestamp;

    var cwd = std.fs.cwd();
    if (cwd.openIterableDir("./repos", .{})) |idir| {
        reset_hits(r.alloc);
        if (Ini.default(r.alloc)) |ini| {
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
                    var name = std.fmt.bufPrint(&buf, "./repos/{s}", .{file.name}) catch return Error.Unknown;
                    _ = findCommits(r.alloc, until, name) catch unreachable;
                },
                else => {},
            }
        }
    } else |_| unreachable;

    var month_i: usize = date.months - 2;
    var stack: [53]HTML.Element = undefined;
    //var day_off: usize = std.math.absCast(@divFloor(date.timestamp - DateTime.today().timestamp, DAY));
    var day_off: usize = 0;
    for (&stack) |*st| {
        var month: []HTML.Element = try r.alloc.alloc(HTML.Element, 8);
        if ((month_i % 12) != date.months - 1) {
            month_i += 1;
            month[0] = HTML.divAttr(DateTime.MONTHS[month_i % 12 + 1][0..3], &monthAtt);
        } else {
            month[0] = HTML.divAttr("&nbsp;", &monthAtt);
        }

        for (month[1..]) |*m| {
            defer date = DateTime.fromEpoch(date.timestamp + DAY) catch unreachable;
            defer day_off += 1;
            var rows = try r.alloc.alloc(HTML.Attribute, 2);
            const class = if (hits[day_off] > 0)
                "day day-commits"
            else if (date.timestamp >= nowish.timestamp)
                "day-hide"
            else
                "day";
            @memcpy(rows, &[2]HTML.Attr{
                HTML.Attr.class(class)[0],
                HTML.Attr{
                    .key = "title",
                    .value = try std.fmt.allocPrint(r.alloc, "{}", .{date}),
                },
            });
            m.* = HTML.divAttr(null, rows);
        }
        st.* = HTML.divAttr(month, &HTML.Attr.class("col"));
    }

    var days = &[_]HTML.Element{
        HTML.divAttr(&[_]HTML.Element{
            HTML.divAttr("&nbsp;", &day),
            HTML.divAttr("Sun", &day),
            HTML.divAttr("Mon", &day),
            HTML.divAttr("Tue", &day),
            HTML.divAttr("Wed", &day),
            HTML.divAttr("Thr", &day),
            HTML.divAttr("Fri", &day),
            HTML.divAttr("Sat", &day),
        }, &HTML.Attr.class("day-col")),
    };

    const flex = HTML.divAttr(
        days ++ stack,
        &HTML.Attr.class("commit-flex"),
    );

    const htm = try std.fmt.allocPrint(r.alloc, "{}", .{flex});
    defer r.alloc.free(htm);

    var tmpl = Template.find("user_commits.html");
    tmpl.init(r.alloc);

    tmpl.addVar("flexes", htm) catch return Error.Unknown;
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;

    r.start() catch return Error.Unknown;
    r.send(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}
