const std = @import("std");

const Allocator = std.mem.Allocator;

const Endpoint = @import("../endpoint.zig");
const Response = Endpoint.Response;
const HTML = Endpoint.HTML;
const Template = Endpoint.Template;
const DateTime = @import("../datetime.zig");
const Commit = @import("../git.zig");

const Error = Endpoint.Error;

const HeatMapArray = [2][13][32]u16;

var hits: HeatMapArray = .{.{.{0} ** 32} ** 13} ** 2;

fn countAll(a: Allocator, root: Commit.Commit, dir: std.fs.Dir) !*HeatMapArray {
    var commit = root;
    while (true) {
        const old = commit.blob;
        const d = commit.author.time;
        hits[d.years - 2022][d.months - 1][d.days - 1] += 1;
        for (commit.parent[1..]) |par| {
            if (par) |p| {
                var parent = try Commit.toParent(a, p, dir);
                _ = try countAll(a, parent, dir);
            }
        }
        commit = try Commit.toParent(a, commit.parent[0] orelse return &hits, dir);
        a.free(old);
    }
}

fn findCommits(a: Allocator, gitdir: []const u8) !*HeatMapArray {
    var repo = try std.fs.cwd().openDir(gitdir, .{});
    defer repo.close();
    var dir = try repo.openDir("./.git/objects/", .{});
    defer dir.close();

    var ref_main = try repo.openFile("./.git/refs/heads/main", .{});
    var b: [1 << 16]u8 = undefined;
    var head = try ref_main.read(&b);

    var fb = [_]u8{0} ** 2048;
    var filename = try std.fmt.bufPrint(&fb, "./.git/objects/{s}/{s}", .{ b[0..2], b[2 .. head - 1] });
    var file = try repo.openFile(filename, .{});
    var commit = try Commit.Commit.readFile(a, file);
    //defer a.free(commit.blob);

    return try countAll(a, commit, dir);
}

fn findCommitsFor(a: Allocator, gitdirs: []const []const u8) !*HeatMapArray {
    for (gitdirs) |gitdir| {
        _ = try findCommits(a, gitdir);
    }
    return &hits;
}

pub fn commitFlex(r: *Response, _: []const u8) Error!void {
    HTML.init(r.alloc);
    defer HTML.raze();

    const day = [1]HTML.Attribute{HTML.Attribute.class("day")};
    const monthAtt = [1]HTML.Attribute{HTML.Attribute.class("month")};

    const today = DateTime.today();
    var date = DateTime.today();
    date = DateTime.fromEpoch(date.timestamp + 60 * 60 * 24 - 31_536_000) catch unreachable;
    while (date.weekday != 0) {
        date = DateTime.fromEpoch(date.timestamp - 60 * 60 * 24) catch unreachable;
    }

    var cwd = std.fs.cwd();
    if (cwd.openIterableDir("./repos", .{})) |idir| {
        var itr = idir.iterate();
        while (itr.next() catch return Error.Unknown) |file| {
            var buf: [1024]u8 = undefined;
            switch (file.kind) {
                .directory, .sym_link => {
                    var name = std.fmt.bufPrint(&buf, "./repos/{s}", .{file.name}) catch return Error.Unknown;
                    _ = findCommits(r.alloc, name) catch unreachable;
                },
                else => {},
            }
        }
    } else |_| unreachable;

    var month_i: usize = date.months - 2;
    var stack: [53]HTML.Element = undefined;
    for (&stack) |*st| {
        var month: []HTML.Element = try r.alloc.alloc(HTML.Element, 8);
        if ((month_i % 12) != date.months - 1) {
            month_i += 1;
            month[0] = HTML.divAttr(DateTime.MONTHS[month_i % 12 + 1][0..3], &monthAtt);
        } else {
            month[0] = HTML.divAttr("&nbsp;", &monthAtt);
        }

        for (month[1..]) |*m| {
            defer date = DateTime.fromEpoch(date.timestamp + 60 * 60 * 24) catch unreachable;
            var rows = try r.alloc.alloc(HTML.Attribute, 2);
            const class = if (hits[date.years - 2022][date.months - 1][date.days - 1] > 0)
                "day day-commits"
            else if (date.timestamp > today.timestamp)
                "day-hide"
            else
                "day";
            @memcpy(rows, &[2]HTML.Attribute{
                HTML.Attribute.class(class),
                HTML.Attribute{
                    .key = "title",
                    .value = try std.fmt.allocPrint(r.alloc, "{}", .{date}),
                },
            });
            m.* = HTML.divAttr(null, rows);
        }
        st.* = HTML.divAttr(month, &[1]HTML.Attribute{HTML.Attribute.class("col")});
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
        }, &[1]HTML.Attribute{HTML.Attribute.class("day-col")}),
    };

    const flex = HTML.divAttr(
        days ++ stack,
        &[1]HTML.Attribute{HTML.Attribute.class("commit-flex")},
    );

    const htm = try std.fmt.allocPrint(r.alloc, "{}", .{flex});
    defer r.alloc.free(htm);

    var tmpl = Template.find("user_commits.html");
    tmpl.init(r.alloc);

    tmpl.addVar("flexes", htm) catch return Error.Unknown;
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;

    r.start() catch return Error.Unknown;
    r.write(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}
