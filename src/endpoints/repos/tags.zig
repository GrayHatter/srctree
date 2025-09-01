const TagPage = PageData("repo-tags.html");

pub fn list(frame: *Frame) Router.Error!void {
    const rd = RouteData.init(frame.uri) orelse return error.Unrouteable;

    var repo = (repos.open(rd.name, .public) catch return error.Unknown) orelse return error.InvalidURI;
    repo.loadData(frame.alloc) catch return error.Unknown;
    defer repo.raze();

    var tstack: []S.Tags = &.{};
    if (repo.tags) |rtags| {
        tstack = try frame.alloc.alloc(S.Tags, rtags.len);
        std.sort.heap(Git.Tag, rtags, {}, sort);

        for (rtags, tstack) |tag, *html_| {
            html_.name = tag.name;
        }
    }

    const upstream: ?S.Upstream = if (repo.findRemote("upstream") catch null) |up| .{
        .href = try allocPrint(frame.alloc, "{f}", .{std.fmt.alt(up, .formatLink)}),
    } else null;

    var page = TagPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = frame.response_data.get(S.BodyHeaderHtml) catch return error.Unknown,
        .upstream = upstream,
        .tags = tstack,
        .repo_name = rd.name,
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
