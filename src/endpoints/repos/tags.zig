const TagPage = PageData("repo-tags.html");

pub fn list(frame: *Frame) Router.Error!void {
    const rd = RouteData.init(frame.uri) orelse return error.Unrouteable;

    const vis: repos.Visibility.Select = if (frame.user) |_| .all else .public_only;
    var repo = (repos.open(rd.name, vis, frame.io) catch return error.Unknown) orelse return error.InvalidURI;
    repo.loadData(frame.alloc, frame.io) catch return error.Unknown;
    defer repo.raze(frame.alloc, frame.io);

    var tags: std.ArrayList(Git.Tag) = .empty;
    for (repo.refs.keys(), repo.refs.values()) |tag_name, ref| switch (ref) {
        .tag => |t| tags.append(frame.alloc, Git.Tag.fromObject(
            repo.objects.load(t, frame.alloc, frame.io) catch continue,
            frame.alloc.dupe(u8, tag_name) catch unreachable,
        ) catch continue) catch unreachable,
        else => {},
    };
    std.sort.heap(Git.Tag, tags.items, {}, sort);
    var tstack: std.ArrayList(S.RepoTagsHtml.Tags) = .empty;
    for (tags.items) |tag| {
        tstack.append(frame.alloc, .{ .name = .abx(tag.name) }) catch unreachable;
    }

    const upstream: ?S.RepoTagsHtml.Upstream = if (repo.findRemote("upstream")) |up| .{
        .href = .abx(try allocPrint(frame.alloc, "{f}", .{std.fmt.alt(up, .formatLink)})),
    } else null;

    var page = TagPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = frame.response_data.get(S.BodyHeaderHtml).?.*,
        .upstream = upstream,
        .tags = tstack.items,
        .repo_name = .abx(rd.name),
    });

    try frame.sendPage(&page);
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
