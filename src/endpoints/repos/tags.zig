const TagPage = PageData("repo-tags.html");

pub fn list(ctx: *Frame) Router.Error!void {
    const rd = RouteData.init(ctx.uri) orelse return error.Unrouteable;

    var repo = (repos.open(rd.name, .public) catch return error.Unknown) orelse return error.InvalidURI;
    repo.loadData(ctx.alloc) catch return error.Unknown;
    defer repo.raze();

    var tstack: []S.Tags = &.{};
    if (repo.tags) |rtags| {
        tstack = try ctx.alloc.alloc(S.Tags, rtags.len);
        std.sort.heap(Git.Tag, rtags, {}, sort);

        for (rtags, tstack) |tag, *html_| {
            html_.name = tag.name;
        }
    }

    const upstream: ?Git.Remote = repo.findRemote("upstream") catch null;

    var page = TagPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml) catch return error.Unknown,
        .upstream = if (upstream) |u| .{ .href = u.fetch orelse "" } else null,
        .tags = tstack,
        .repo_name = rd.name,
    });

    try ctx.sendPage(&page);
}

pub fn sort(_: void, l: Git.Tag, r: Git.Tag) bool {
    return l.tagger.timestamp >= r.tagger.timestamp;
}

const repos_ = @import("../repos.zig");
const RouteData = repos_.RouteData;

const std = @import("std");
const verse = @import("verse");
const Frame = verse.Frame;
const S = verse.template.Structs;
const PageData = verse.template.PageData;
const Router = verse.Router;
const repos = @import("../../repos.zig");
const Git = @import("../../git.zig");
