const TreePage = PageData("tree.html");

pub fn tree(ctx: *Frame, rd: RouteData, repo: *Git.Repo, files: *Git.Tree) Router.Error!void {
    //const head = if (repo.head) |h| switch (h) {
    //    .sha => |s| s.hex()[0..],
    //    .branch => |b| b.name,
    //    else => "unknown",
    //} else "unknown";
    //ctx.putVerse("Branch.default", .{ .slice = head }) catch return error.Unknown;

    var dom = html.DOM.new(ctx.alloc);

    dom = dom.open(html.element("repo", null, &html.Attr.class("landing")));

    dom = dom.open(html.element("intro", null, null));
    dom.push(html.h3(rd.name, null));
    const branches = try allocPrint(ctx.alloc, "{} branches", .{repo.refs.len});
    dom.push(html.span(branches, null));

    const c = if (rd.ref) |ref|
        switch (repo.loadObject(ctx.alloc, .init(ref)) catch return error.InvalidURI) {
            .commit => |cm| cm,
            else => return error.DataInvalid,
        }
    else
        repo.headCommit(ctx.alloc) catch return error.Unknown;

    dom.push(html.span(c.title[0..@min(c.title.len, 50)], null));
    const commit_time = try allocPrint(ctx.alloc, "  {}", .{Humanize.unix(c.committer.timestamp)});
    dom = dom.open(html.span(null, &html.Attr.class("muted")));
    const commit_href = try allocPrint(ctx.alloc, "/repo/{s}/commit/{s}", .{ rd.name, c.sha.hex()[0..8] });
    dom.push(html.text(commit_time));
    dom.push(try html.aHrefAlloc(ctx.alloc, c.sha.hex()[0..8], commit_href));
    dom = dom.close();
    dom = dom.close();

    dom = dom.open(html.div(null, &html.Attr.class("treelist")));
    if (rd.target) |_| {
        //const end = std.mem.lastIndexOf(u8, "", "/") orelse 0;
        dom = dom.open(html.element("tree", null, null));
        const dd_href = &[_]html.Attribute{.{
            .key = "href",
            .value = try allocPrint(
                ctx.alloc,
                "/repo/{s}/tree/{s}",
                .{ rd.name, "" },
            ),
        }};
        dom.dupe(html.anch("..", dd_href));
        dom = dom.close();
    }
    try files.pushPath(ctx.alloc, "");
    if (files.changedSetFrom(ctx.alloc, repo, c.sha)) |changed| {
        std.sort.pdq(Git.Blob, files.blobs, {}, typeSorter);
        for (files.blobs) |obj| {
            for (changed) |ch| {
                if (std.mem.eql(u8, ch.name, obj.name)) {
                    dom = try drawFileLine(ctx.alloc, dom, rd.name, "", obj, ch);
                    break;
                }
            }
        }
    } else |err| switch (err) {
        error.PathNotFound => {
            dom.push(html.h3("unable to find this file", null));
        },
        else => return error.Unrouteable,
    }
    dom = dom.close();

    dom = dom.close();
    const repo_data = dom.done();

    var readme: ?[]const u8 = null;

    for (files.blobs) |obj| {
        if (isReadme(obj.name)) {
            const resolve = repo.blob(ctx.alloc, obj.sha) catch return error.Unknown;
            const readme_html = htmlReadme(ctx.alloc, resolve.data.?) catch unreachable;
            readme = try std.fmt.allocPrint(ctx.alloc, "{pretty}", .{readme_html[0]});
            break;
        }
    }

    //var btns = navButtons(ctx) catch return error.Unknown;
    var page_desc: ?[]const u8 = repo.description(ctx.alloc) catch null;
    if (page_desc) |pd| {
        if (std.mem.startsWith(u8, pd, "Unnamed repository; edit this file"))
            page_desc = null;
    }

    const page_title = try allocPrint(ctx.alloc, "{s}{s}{s} - srctree", .{
        rd.name,
        if (page_desc) |_| " - " else "",
        page_desc orelse "",
    });

    var page = TreePage.init(.{
        .meta_head = .{ .title = page_title, .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch return error.Unknown,
        .upstream = null,
        .repo_name = rd.name,
        .repo = try allocPrint(ctx.alloc, "{s}", .{repo_data[0]}),
        .readme = readme,
    });

    try ctx.sendPage(&page);
}

const dirs_first = true;
fn typeSorter(_: void, l: Git.Blob, r: Git.Blob) bool {
    if (l.isFile() == r.isFile()) return sorter({}, l.name, r.name);
    if (l.isFile() and !r.isFile()) return !dirs_first;
    return dirs_first;
}

fn drawFileLine(
    a: Allocator,
    ddom: *html.DOM,
    rname: []const u8,
    base: []const u8,
    obj: Git.Blob,
    ch: Git.ChangeSet,
) !*html.DOM {
    var dom = ddom;
    if (obj.isFile()) {
        dom = try drawBlob(a, dom, rname, base, obj);
    } else {
        dom = try drawTree(a, dom, rname, base, obj);
    }

    // I know... I KNOW!!!
    dom = dom.open(html.div(null, null));
    const commit_href = try allocPrint(a, "/repo/{s}/commit/{s}", .{ rname, ch.sha.hex()[0..8] });
    dom.push(try html.aHrefAlloc(a, ch.commit_title, commit_href));
    dom.dupe(html.span(try allocPrint(a, "{}", .{Humanize.unix(ch.timestamp)}), null));
    dom = dom.close();
    return dom.close();
}

fn isReadme(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, "README.md")) return true;
    return false;
}

fn htmlReadme(a: Allocator, readme: []const u8) ![]html.E {
    var dom = html.DOM.new(a);

    dom = dom.open(html.element("readme", null, null));
    dom.push(html.element("intro", "README.md", null));
    dom = dom.open(html.element("code", null, null));
    const translated = try Highlight.translate(a, .markdown, readme);
    dom.push(html.text(translated));
    dom = dom.close();
    dom = dom.close();

    return dom.done();
}

fn sorter(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

fn drawBlob(a: Allocator, ddom: *html.DOM, rname: []const u8, base: []const u8, obj: Git.Blob) !*html.DOM {
    var dom = ddom.open(html.element("file", null, null));
    const file_link = try allocPrint(a, "/repo/{s}/blob/{s}{s}", .{ rname, base, obj.name });

    const href = &[_]html.Attribute{.{
        .key = "href",
        .value = file_link,
    }};
    dom.dupe(html.anch(obj.name, href));

    return dom;
}

fn drawTree(a: Allocator, ddom: *html.DOM, rname: []const u8, base: []const u8, obj: Git.Blob) !*html.DOM {
    var dom = ddom.open(html.element("tree", null, null));
    const file_link = try allocPrint(a, "/repo/{s}/tree/{s}{s}/", .{ rname, base, obj.name });

    const href = &[_]html.Attribute{.{
        .key = "href",
        .value = file_link,
    }};
    dom.dupe(html.anch(try dupeDir(a, obj.name), href));
    return dom;
}

fn dupeDir(a: Allocator, name: []const u8) ![]u8 {
    var out = try a.alloc(u8, name.len + 1);
    @memcpy(out[0..name.len], name);
    out[name.len] = '/';
    return out;
}

const repos_ = @import("../repos.zig");
const RouteData = repos_.RouteData;

const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;

const verse = @import("verse");
const Frame = verse.Frame;
const S = verse.template.Structs;
const html = verse.template.html;
const PageData = verse.template.PageData;
const Router = verse.Router;
const Humanize = @import("../../humanize.zig");
const repos = @import("../../repos.zig");
const Git = @import("../../git.zig");
const Highlight = @import("../../syntax-highlight.zig");
