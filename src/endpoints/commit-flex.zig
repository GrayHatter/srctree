const std = @import("std");

const Allocator = std.mem.Allocator;

const Endpoint = @import("../endpoint.zig");
const Response = Endpoint.Response;
const HTML = Endpoint.HTML;
const Template = Endpoint.Template;
const DateTime = @import("../datetime.zig");
const Commit = @import("../git.zig");

const Error = Endpoint.Error;

var hits: [2][13][32]u32 = .{.{.{0} ** 32} ** 13} ** 2;

fn countAll(a: Allocator, root: Commit.Commit, dir: std.fs.Dir) !void {
    var commit = root;
    while (true) {
        const old = commit.blob;
        const d = commit.author.time;
        hits[d.years - 2022][d.months - 1][d.days - 1] += 1;
        for (commit.parent[1..]) |par| {
            if (par) |p| {
                var parent = try Commit.toParent(a, p, dir);
                try countAll(a, parent, dir);
            }
        }
        commit = try Commit.toParent(a, commit.parent[0] orelse return, dir);
        a.free(old);
    }
}

fn findCommits(a: Allocator, gitdir: []const u8) !void {
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

    try countAll(a, commit, dir);
}

pub fn commitFlex(r: *Response, _: []const u8) Error!void {
    var tmpl = Template.find("user_commits.html");
    tmpl.alloc = r.alloc;

    HTML.init(r.alloc);
    defer HTML.raze();

    const day = [1]HTML.Attribute{HTML.Attribute.class("day")};
    const monthAtt = [1]HTML.Attribute{HTML.Attribute.class("month")};

    var date = DateTime.today();
    date = DateTime.fromEpoch(date.timestamp + 60 * 60 * 24 - 31_536_000) catch unreachable;
    while (date.weekday != 0) {
        date = DateTime.fromEpoch(date.timestamp - 60 * 60 * 24) catch unreachable;
    }

    findCommits(r.alloc, ".") catch unreachable;
    findCommits(r.alloc, "../hsh/") catch unreachable;
    findCommits(r.alloc, "../gr.ht.hugo/") catch unreachable;

    var month_i: usize = date.months - 2;
    var stack: [53]HTML.Element = undefined;
    for (&stack) |*st| {
        var month: []HTML.Element = try r.alloc.alloc(HTML.Element, 8);
        if ((month_i % 12) != date.months - 1) {
            month_i += 1;
            month[0] = HTML.divAttr(DateTime.MONTHS[month_i % 12 + 1][0..3], &monthAtt);
        } else {
            month[0] = HTML.divAttr(null, &monthAtt);
        }

        for (month[1..]) |*m| {
            defer date = DateTime.fromEpoch(date.timestamp + 60 * 60 * 24) catch unreachable;
            var rows = try r.alloc.alloc(HTML.Attribute, 2);
            @memcpy(rows, &[2]HTML.Attribute{
                HTML.Attribute.class(if (hits[date.years - 2022][date.months - 1][date.days - 1] > 0) "day day-commits" else "day"),
                HTML.Attribute{
                    .key = "title",
                    .value = try std.fmt.allocPrint(r.alloc, "{}", .{date}),
                },
            });
            m.* = HTML.divAttr(null, rows);
        }
        st.* = HTML.divAttr(month, &[1]HTML.Attribute{HTML.Attribute.class("col")});
    }
    defer for (stack) |s| r.alloc.free(s.children.?);

    var now = DateTime.now();
    std.debug.print("{any}\n", .{now});

    std.debug.print("{}\n", .{DateTime.DAYS_IN_MONTH[now.months] - (now.days - now.weekday)});

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

    tmpl.addVar("flexes", htm) catch return Error.Unknown;

    var page = std.fmt.allocPrint(r.alloc, "{}", .{tmpl}) catch unreachable;
    r.start() catch return Error.Unknown;
    r.write(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}
