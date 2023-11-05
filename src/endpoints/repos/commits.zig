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

pub fn commit(r: *Response, uri: *UriIter) Error!void {
    const rd = RouteData.make(uri) orelse return error.Unrouteable;
    if (rd.verb == null) return commits(r, uri);

    var cwd = std.fs.cwd();
    // FIXME user data flows into system
    var filename = try std.fmt.allocPrint(r.alloc, "./repos/{s}", .{rd.name});
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadPacks(r.alloc) catch return error.Unknown;

    var tmpl = Template.find("commit.html");
    tmpl.init(r.alloc);

    if (rd.noun) |sha| {
        if (!git.commitish(sha)) {
            std.debug.print("Abusive ''{s}''\n", .{sha});
            return error.Abusive;
        }

        var lcommits = try r.alloc.alloc(HTML.E, 1);
        var current: git.Commit = repo.commit(r.alloc) catch return error.Unknown;
        while (!std.mem.startsWith(u8, current.sha, sha)) {
            current = current.toParent(r.alloc, 0) catch return error.Unknown;
        }
        lcommits[0] = (try htmlCommit(r.alloc, current, true))[0];

        var acts = repo.getActions(r.alloc);
        var diff = acts.show(sha) catch return error.Unknown;
        if (std.mem.indexOf(u8, diff, "diff")) |i| {
            diff = diff[i..];
        }
        var dom = DOM.new(r.alloc);
        dom.push(HTML.element("diff", diff, null));
        const data = dom.done();
        _ = tmpl.addElements(r.alloc, "diff", data) catch return error.Unknown;
        const htmlstr = try std.fmt.allocPrint(r.alloc, "{}", .{
            HTML.div(lcommits),
        });

        tmpl.addVar("commits", htmlstr) catch return error.Unknown;
    }

    var page = tmpl.buildFor(r.alloc, r) catch unreachable;

    r.status = .ok;
    r.start() catch return Error.Unknown;
    r.write(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}

pub fn htmlCommit(a: Allocator, c: git.Commit, comptime top: bool) ![]HTML.E {
    var dom = DOM.new(a);
    dom = dom.open(HTML.element("commit", null, null));

    if (!top) {
        dom.push(HTML.element(
            "data",
            try std.fmt.allocPrint(a, "{s}<br>{s}", .{ c.sha[0..8], c.message }),
            null,
        ));
    }

    dom = dom.open(HTML.element(if (top) "top" else "foot", null, null));
    {
        const prnt = c.parent[0] orelse "00000000";
        dom.push(HTML.element("author", try a.dupe(u8, c.author.name), null));
        dom.push(HTML.span(try std.fmt.allocPrint(a, "parent {s}", .{prnt[0..8]})));
    }
    dom = dom.close();

    if (top) {
        dom.push(HTML.element(
            "data",
            try std.fmt.allocPrint(a, "{s}<br>{s}", .{ c.sha[0..8], c.message }),
            null,
        ));
    }
    dom = dom.close();
    return dom.done();
}

pub fn commits(r: *Response, uri: *UriIter) Error!void {
    uri.reset();
    _ = uri.next();
    var name = uri.next() orelse return error.Unrouteable;

    var filename = try std.fmt.allocPrint(r.alloc, "./repos/{s}", .{name});
    var cwd = std.fs.cwd();
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;
    repo.loadPacks(r.alloc) catch return error.Unknown;

    var lcommits = try r.alloc.alloc(HTML.E, 50);
    var current: git.Commit = repo.commit(r.alloc) catch return error.Unknown;
    for (lcommits, 0..) |*c, i| {
        c.* = (try htmlCommit(r.alloc, current, false))[0];
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
