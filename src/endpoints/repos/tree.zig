const TreePage = PageData("tree.html");

fn filenameIsHidden(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '.') return true;
    return eql(u8, name, "README.md") or
        eql(u8, name, "CONTRIBUTING.md") or
        eql(u8, name, "LICENSE.md");
}

pub fn tree(ctx: *Frame, rd: RouteData, repo: *Git.Repo, files: *Git.Tree) Router.Error!void {
    const now: i64 = Io.Clock.real.now(ctx.io).toSeconds();
    const c = if (rd.ref) |ref|
        switch (repo.objects.load(.init(ref), ctx.alloc, ctx.io) catch return error.InvalidURI) {
            .commit => |cm| cm,
            else => return error.DataInvalid,
        }
    else
        repo.HEAD(ctx.alloc, ctx.io) catch return error.Unknown;

    const branch_count = repo.refs.count();
    const commit_slug = std.mem.trim(u8, c.title[0..@min(c.title.len, 50)], " \n");
    const commit_time = try allocPrint(ctx.alloc, "{f}", .{Humanize.unix(c.committer.timestamp, now)});
    const commit_text = c.sha.text();
    const commit_hex = commit_text.slice();
    const commit_hex_short = commit_hex[0..8];

    const prefix = if (rd.ref) |ref|
        try allocPrint(ctx.alloc, "/repo/{s}/ref/{s}", .{ rd.name, ref })
    else
        try allocPrint(ctx.alloc, "/repo/{s}", .{rd.name});

    const path: ?[]const u8 = if (rd.path) |p| p.path else null;

    var list_trees: ArrayList(S.TreeHtml.Trees) = .empty;
    var list_files: ArrayList(S.TreeHtml.Files) = .empty;
    var list_hidden: ArrayList(S.TreeHtml.Hidden.HiddenFiles) = .empty;

    var itr = files.iterate();
    const blobs = try itr.toSlice(ctx.alloc);

    if (files.changedSetFrom(repo, &c, ctx.alloc, ctx.io)) |changed| {
        std.sort.pdq(Git.Blob, blobs, {}, sorter);
        for (blobs) |obj| {
            for (changed) |ch| {
                if (std.mem.eql(u8, ch.name, obj.name)) {
                    const sha_text = ch.sha.text();
                    const chref = try allocPrint(ctx.alloc, "/repo/{s}/commit/{s}", .{ rd.name, sha_text.slice()[0..8] });
                    const ctime = try allocPrint(ctx.alloc, "{f}", .{Humanize.unix(ch.timestamp, now)});
                    const href: []const u8 = if (obj.isFile())
                        try allocPrint(ctx.alloc, "{s}/blob/{s}{s}", .{ prefix, path orelse "", obj.name })
                    else
                        try allocPrint(ctx.alloc, "{s}/tree/{s}{s}", .{ prefix, path orelse "", obj.name });
                    if (filenameIsHidden(ch.name)) {
                        try list_hidden.append(ctx.alloc, .{
                            .name = .abx(ch.name),
                            .href = .abx(href),
                            .commit_title = .abx(ch.title),
                            .commit_href = .safe(chref),
                            .commit_time = .safe(ctime),
                            .class = .safe(if (obj.isFile()) "file" else "tree"),
                        });
                    } else if (obj.isFile()) {
                        try list_files.append(ctx.alloc, .{
                            .name = .abx(ch.name),
                            .href = .abx(href),
                            .commit_title = .abx(ch.title),
                            .commit_href = .safe(chref),
                            .commit_time = .safe(ctime),
                        });
                    } else {
                        try list_trees.append(ctx.alloc, .{
                            .name = .abx(ch.name),
                            .href = .abx(href),
                            .commit_title = .abx(ch.title),
                            .commit_href = .safe(chref),
                            .commit_time = .safe(ctime),
                        });
                    }
                    break;
                }
            }
        }
    } else |err| switch (err) {
        else => return error.ServerFault,
    }

    var readme: ?[]const u8 = null;
    for (blobs) |obj| {
        if (isReadme(obj.name)) {
            const resolve = repo.blob(obj.sha, ctx.alloc, ctx.io) catch return error.Unknown;
            const readme_html = htmlReadme(resolve.bytes, ctx.alloc, ctx.io) catch unreachable;
            readme = try allocPrint(ctx.alloc, "{f}", .{readme_html[0]});
            break;
        }
    }

    const page_desc: ?[]const u8 = try allocPrint(ctx.alloc, "{f}", .{
        abx.Html{ .text = repo.description(ctx.alloc, ctx.io) catch "" },
    });
    const open_graph: S.OpenGraph = .{ .title = rd.name, .desc = page_desc orelse "" };

    const page_title = if (page_desc) |pd|
        try allocPrint(ctx.alloc, "{s} - {s} - srctree", .{ rd.name, pd })
    else
        try allocPrint(ctx.alloc, "{s} - srctree", .{rd.name});

    const upstream: ?S.BaseRepoHeaderHtml.Upstream = if (repo.findRemote("upstream")) |up| .{
        .href = .abx(try allocPrint(ctx.alloc, "{f}", .{std.fmt.alt(up, .formatLink)})),
    } else null;

    var page = TreePage.init(.{
        .meta_head = .{ .title = page_title, .open_graph = open_graph },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml).?.*,
        .repo_header = .{
            .git_uri = .{ .host = .safe(try ctx.request.host.?.valid()), .repo_name = .abx(rd.name) },
            .description = .abx(open_graph.desc),
            .repo_name = .abx(rd.name),
            .upstream = upstream,
            .blame = null,
        },
        .repo_name = .abx(rd.name),
        .readme = readme,
        .commit_slug = .abx(commit_slug),
        .commit_time_human = .safe(commit_time),
        //.commit_hex = commit_hex,
        .commit_hex_short = .abx(commit_hex_short),
        .dot_dot = files.parent != null,
        .branch_count = branch_count,
        .trees = list_trees.items,
        .files = list_files.items,
        .hidden = if (list_hidden.items.len == 0) null else .{
            .count = list_hidden.items.len,
            .hidden_files = list_hidden.items,
        },
    });

    try ctx.sendPage(&page);
}

fn sorter(_: void, l: Git.Blob, r: Git.Blob) bool {
    return std.mem.lessThan(u8, l.name, r.name);
}

fn isReadme(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, "README.md")) return true;
    return false;
}

fn htmlReadme(readme: []const u8, a: Allocator, io: Io) ![]E {
    var dom: *DOM = .create(a);

    dom = dom.open(html.element("readme", &.{}, &.{}));
    dom.push(html.element("intro", &.{.text("README.md")}, &.{}));
    dom = dom.open(html.element("code", &.{}, &.{}));

    var r: Reader = .fixed(readme);
    var w: Writer.Allocating = try .initCapacity(a, readme.len);
    Highlight.Markdown.translate(&r, &w.writer, a, io) catch |err| switch (err) {
        error.InvalidMarkdown => try w.writer.print("{f}", .{abx.Html{ .text = readme }}),
        error.OutOfMemory, error.WriteFailed => return error.ServerFault,
    };
    dom.push(html.text(w.written()));
    dom = dom.close();
    dom = dom.close();

    return dom.done();
}

const repos_ = @import("../repos.zig");
const RouteData = repos_.RouteData;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const allocPrint = std.fmt.allocPrint;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;

const verse = @import("verse");
const Frame = verse.Frame;
const abx = verse.Antibiotic;
const S = verse.template.Structs;
const html = verse.template.html;
const DOM = html.DOM;
const E = html.E;

const PageData = verse.template.PageData;
const Router = verse.Router;
const Humanize = @import("../../humanize.zig");
const repos = @import("../../repos.zig");
const Git = @import("../../git.zig");
const Highlight = @import("../../syntax-highlight.zig");
