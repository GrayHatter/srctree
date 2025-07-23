const TreePage = PageData("tree.html");

pub fn tree(ctx: *Frame, rd: RouteData, repo: *Git.Repo, files: *Git.Tree) Router.Error!void {
    const c = if (rd.ref) |ref|
        switch (repo.loadObject(ctx.alloc, .init(ref)) catch return error.InvalidURI) {
            .commit => |cm| cm,
            else => return error.DataInvalid,
        }
    else
        repo.headCommit(ctx.alloc) catch return error.Unknown;

    const branch_count = repo.refs.len;
    const commit_slug = std.mem.trim(u8, c.title[0..@min(c.title.len, 50)], " \n");
    const commit_time = try allocPrint(ctx.alloc, "{}", .{Humanize.unix(c.committer.timestamp)});
    const commit_hex = c.sha.hex()[0..40];
    const commit_hex_short = commit_hex[0..8];

    const path: ?[]const u8 = if (rd.path) |p| p.buffer else null;

    const prefix = if (rd.ref) |ref|
        try allocPrint(ctx.alloc, "/repo/{s}/ref/{s}", .{ rd.name, ref })
    else
        try allocPrint(ctx.alloc, "/repo/{s}", .{rd.name});

    const dot_dot: ?S.DotDot = if (path) |p| .{
        // TODO fix
        .href = try allocPrint(ctx.alloc, "{s}/tree/{s}", .{ prefix, p }),
    } else null;

    var list_trees: std.ArrayListUnmanaged(S.CommitFilelistTrees) = .{};
    var list_files: std.ArrayListUnmanaged(S.CommitFilelistFiles) = .{};

    if (path) |p| try files.pushPath(ctx.alloc, p);
    if (files.changedSetFrom(ctx.alloc, repo, c.sha)) |changed| {
        std.sort.pdq(Git.Blob, files.blobs, {}, sorter);
        for (files.blobs) |obj| {
            for (changed) |ch| {
                if (std.mem.eql(u8, ch.name, obj.name)) {
                    const chref = try allocPrint(ctx.alloc, "/repo/{s}/commit/{s}", .{ rd.name, ch.sha.hex()[0..8] });
                    const ctime = try allocPrint(ctx.alloc, "{}", .{Humanize.unix(ch.timestamp)});
                    if (obj.isFile()) {
                        const href = try allocPrint(ctx.alloc, "{s}/blob/{s}{s}", .{
                            prefix, path orelse "", obj.name,
                        });
                        try list_files.append(ctx.alloc, .{
                            .name = ch.name,
                            .href = href,
                            .commit_title = ch.commit_title,
                            .commit_href = chref,
                            .commit_time = ctime,
                        });
                    } else {
                        const href = try allocPrint(ctx.alloc, "{s}/tree/{s}{s}/", .{
                            prefix, path orelse "", obj.name,
                        });
                        try list_trees.append(ctx.alloc, .{
                            .name = ch.name,
                            .href = href,
                            .commit_title = ch.commit_title,
                            .commit_href = chref,
                            .commit_time = ctime,
                        });
                    }
                    break;
                }
            }
        }
    } else |err| switch (err) {
        error.PathNotFound => {}, //dom.push(html.h3("unable to find this file", null));
        else => return error.Unrouteable,
    }

    var readme: ?[]const u8 = null;
    for (files.blobs) |obj| {
        if (isReadme(obj.name)) {
            const resolve = repo.blob(ctx.alloc, obj.sha) catch return error.Unknown;
            const readme_html = htmlReadme(ctx.alloc, resolve.data.?) catch unreachable;
            readme = try allocPrint(ctx.alloc, "{pretty}", .{readme_html[0]});
            break;
        }
    }

    var open_graph: S.OpenGraph = .{ .title = rd.name };
    var page_desc: ?[]const u8 = null;
    if (repo.description(ctx.alloc)) |desc| {
        if (!std.mem.startsWith(u8, desc, "Unnamed repository; edit this file")) {
            page_desc = std.mem.trim(u8, desc, " \n\r\t");
            open_graph.desc = page_desc.?;
        }
    } else |_| {}

    const page_title = if (page_desc) |pd|
        try allocPrint(ctx.alloc, "{s} - {s} - srctree", .{ rd.name, pd })
    else
        try allocPrint(ctx.alloc, "{s} - srctree", .{rd.name});

    const upstream: ?S.Upstream = if (repo.findRemote("upstream") catch null) |up| .{
        .href = try allocPrint(ctx.alloc, "{link}", .{up}),
    } else null;

    var page = TreePage.init(.{
        .meta_head = .{ .title = page_title, .open_graph = open_graph },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch return error.Unknown,
        .tree_blob_header = .{
            .git_uri = .{
                .host = "srctree.gr.ht",
                .repo_name = rd.name,
            },
            .repo_name = rd.name,
            .upstream = upstream,
            .blame = null,
        },
        .repo_name = rd.name,
        .readme = readme,
        .commit_slug = commit_slug,
        .commit_time_human = commit_time,
        //.commit_hex = commit_hex,
        .commit_hex_short = commit_hex_short,
        .dot_dot = dot_dot,
        .branch_count = branch_count,
        .commit_filelist_trees = list_trees.items,
        .commit_filelist_files = list_files.items,
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

fn htmlReadme(a: Allocator, readme: []const u8) ![]E {
    var dom: *DOM = .create(a);

    dom = dom.open(html.element("readme", null, null));
    dom.push(html.element("intro", "README.md", null));
    dom = dom.open(html.element("code", null, null));
    const translated = try Highlight.translate(a, .markdown, readme);
    dom.push(html.text(translated));
    dom = dom.close();
    dom = dom.close();

    return dom.done();
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
const DOM = html.DOM;
const E = html.E;

const PageData = verse.template.PageData;
const Router = verse.Router;
const Humanize = @import("../../humanize.zig");
const repos = @import("../../repos.zig");
const Git = @import("../../git.zig");
const Highlight = @import("../../syntax-highlight.zig");
