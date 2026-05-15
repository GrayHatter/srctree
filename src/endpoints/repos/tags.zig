const TagPage = PageData("repo-tags.html");

pub fn list(f: *Frame) Router.Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;

    const vis: repos.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo = (repos.open(rd.name, vis, f.io) catch return error.Unknown) orelse return error.InvalidURI;
    repo.loadData(f.alloc, f.io) catch return error.Unknown;
    defer repo.raze(f.alloc, f.io);

    var tags: std.ArrayList(Git.Tag) = .empty;
    for (repo.refs.keys(), repo.refs.values()) |tag_name, ref| switch (ref) {
        .tag => |t| tags.append(f.alloc, Git.Tag.fromObject(
            repo.objects.load(t, f.alloc, f.io) catch continue,
            f.alloc.dupe(u8, tag_name) catch unreachable,
        ) catch continue) catch unreachable,
        else => {},
    };
    std.sort.heap(Git.Tag, tags.items, {}, sort);
    var tstack: std.ArrayList(S.RepoTagsHtml.Tags) = .empty;
    for (tags.items) |tag| {
        tstack.append(f.alloc, .{ .name = .abx(tag.name) }) catch unreachable;
    }

    //const open_graph: S.OpenGraph = .{ .title = rd.name, .desc = page_desc orelse "" };
    const repo_header: S.BaseRepoHeaderHtml = .{
        .git_uri = .{ .host = .safe("srctree.gr.ht"), .repo_name = .abx(rd.name) },
        .repo_name = .safe(rd.name),
        .description = .abx(repo.description(f.alloc, f.io) catch ""),
        .upstream = if (repo.findRemote("upstream")) |up| .{
            .href = .abx(try allocPrint(f.alloc, "{f}", .{std.fmt.alt(up, .formatLink)})),
        } else null,
        .blame = null,
    };

    var page = TagPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = f.response_data.get(S.BodyHeaderHtml).?.*,
        .repo_header = repo_header,
        .tags = tstack.items,
    });

    try f.sendPage(&page);
}

pub fn sort(_: void, l: Git.Tag, r: Git.Tag) bool {
    return l.tagger.timestamp >= r.tagger.timestamp;
}

const repos_ = @import("../repos.zig");
const RouteData = repos_.RouteData;

const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const verse = @import("verse");
const Frame = verse.Frame;
const S = verse.template.Structs;
const PageData = verse.template.PageData;
const Router = verse.Router;
const repos = @import("../../repos.zig");
const Git = @import("../../git.zig");
