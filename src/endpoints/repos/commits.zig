const std = @import("std");

const Allocator = std.mem.Allocator;

const Repos = @import("../repos.zig");
const Endpoint = @import("../../endpoint.zig");

const Response = Endpoint.Response;
const HTML = Endpoint.HTML;
const DOM = Endpoint.DOM;
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;
const RouteData = Repos.RouteData;

const git = @import("../../git.zig");
const Bleach = @import("../../bleach.zig");

fn diffLine(a: Allocator, diff: []const u8) *DOM {
    var dom = DOM.new(a);

    const count = std.mem.count(u8, diff, "\n");
    dom = dom.open(HTML.element("diff", null, null));
    var litr = std.mem.split(u8, diff, "\n");

    for (0..count + 1) |_| {
        const a_add = &[1]HTML.Attr{HTML.Attr.class("add")};
        const a_del = &[1]HTML.Attr{HTML.Attr.class("del")};
        const dirty = litr.next().?;
        var clean = a.alloc(u8, dirty.len * 2) catch unreachable;
        clean = Bleach.sanitize(dirty, clean, .{}) catch unreachable;
        const attr: ?[]const HTML.Attr = if (clean.len > 0 and (clean[0] == '-' or clean[0] == '+'))
            if (clean[0] == '-') a_del else a_add
        else
            null;
        dom.push(HTML.span(clean, attr));
    }

    dom = dom.close();

    return dom;
}

pub fn commit(r: *Response, uri: *UriIter) Error!void {
    const rd = RouteData.make(uri) orelse return error.Unrouteable;
    if (rd.verb == null) return commits(r, uri);

    var cwd = std.fs.cwd();
    // FIXME user data flows into system
    var filename = try std.fmt.allocPrint(r.alloc, "./repos/{s}", .{rd.name});
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(r.alloc) catch return error.Unknown;

    var tmpl = Template.find("commit.html");
    tmpl.init(r.alloc);

    if (rd.noun) |sha| {
        if (!git.commitish(sha)) {
            std.debug.print("Abusive ''{s}''\n", .{sha});
            return error.Abusive;
        }

        var commit_view = try r.alloc.alloc(HTML.E, 1);
        var current: git.Commit = repo.commit(r.alloc) catch return error.Unknown;
        while (!std.mem.startsWith(u8, current.sha, sha)) {
            current = current.toParent(r.alloc, 0) catch return error.Unknown;
        }
        commit_view[0] = (try htmlCommit(r.alloc, current, rd.name, true))[0];

        var acts = repo.getActions(r.alloc);
        var diff = acts.show(sha) catch return error.Unknown;
        if (std.mem.indexOf(u8, diff, "diff")) |i| {
            diff = diff[i..];
        }

        var diff_lines = diffLine(r.alloc, diff);

        const diff_els = diff_lines.done();
        _ = tmpl.addElementsFmt(r.alloc, "{pretty}", "diff", diff_els) catch return error.Unknown;
        const htmlstr = try std.fmt.allocPrint(r.alloc, "{}", .{
            HTML.div(commit_view),
        });

        tmpl.addVar("commits", htmlstr) catch return error.Unknown;
    }

    var page = tmpl.buildFor(r.alloc, r) catch unreachable;

    r.status = .ok;
    r.start() catch return Error.Unknown;
    r.write(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}

pub fn htmlCommit(a: Allocator, c: git.Commit, repo: []const u8, comptime top: bool) ![]HTML.E {
    var dom = DOM.new(a);
    dom = dom.open(HTML.element("commit", null, null));

    var cd_dom = DOM.new(a);
    cd_dom = cd_dom.open(HTML.element("data", null, null));
    cd_dom.push(try HTML.aHrefText(
        a,
        c.sha[0..8],
        try std.fmt.allocPrint(a, "/repo/{s}/commit/{s}", .{ repo, c.sha[0..8] }),
    ));
    cd_dom.push(HTML.br());
    cd_dom.push(HTML.text(c.message));
    cd_dom = cd_dom.close();
    const cdata = cd_dom.done();

    if (!top) dom.pushSlice(cdata);

    dom = dom.open(HTML.element(if (top) "top" else "foot", null, null));
    {
        const prnt = c.parent[0] orelse "00000000";
        dom.push(HTML.element("author", try a.dupe(u8, c.author.name), null));
        dom = dom.open(HTML.span(null, null));
        dom.push(HTML.text("parent "));
        dom.push(try HTML.aHrefText(
            a,
            prnt[0..8],
            try std.fmt.allocPrint(a, "/repo/{s}/commit/{s}", .{ repo, prnt[0..8] }),
        ));
        dom = dom.close();
    }
    dom = dom.close();

    if (top) dom.pushSlice(cdata);

    dom = dom.close();
    return dom.done();
}

pub fn commits(r: *Response, uri: *UriIter) Error!void {
    const rd = RouteData.make(uri) orelse return error.Unrouteable;

    var filename = try std.fmt.allocPrint(r.alloc, "./repos/{s}", .{rd.name});
    var cwd = std.fs.cwd();
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(r.alloc) catch return error.Unknown;

    var lcommits = try r.alloc.alloc(HTML.E, 50);
    var current: git.Commit = repo.commit(r.alloc) catch return error.Unknown;
    for (lcommits, 0..) |*c, i| {
        c.* = (try htmlCommit(r.alloc, current, rd.name, false))[0];
        current = current.toParent(r.alloc, 0) catch {
            lcommits.len = i;
            break;
        };
    }

    const htmlstr = try std.fmt.allocPrint(r.alloc, "{}", .{
        HTML.div(lcommits),
    });

    var tmpl = Template.find("commits.html");
    tmpl.init(r.alloc);
    tmpl.addVar("commits", htmlstr) catch return error.Unknown;

    var page = tmpl.buildFor(r.alloc, r) catch unreachable;

    r.status = .ok;
    r.start() catch return Error.Unknown;
    r.write(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}
