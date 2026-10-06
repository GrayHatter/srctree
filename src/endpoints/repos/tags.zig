const TagPage = PageData("repo-tags.html");

pub fn list(f: *Frame) Router.Error!void {
    const rd = RouteData.init(f) orelse return error.ServerFault;

    const vis: Repo.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo = (Repo.openGit(rd.name, vis, f.io) catch return error.Unknown) orelse return error.InvalidURI;
    repo.loadData(f.alloc, f.io) catch return error.Unknown;
    defer repo.raze(f.alloc, f.io);

    var tags: std.ArrayList(Git.Tag) = .empty;
    for (repo.refs.map.keys(), repo.refs.map.values()) |tag_name, ref| {
        switch (ref) {
            .tag => |t| {
                const sha: Git.Sha = .init(t);
                const obj = repo.objects.load(sha, f.alloc, f.io) catch |err| {
                    log.err("{}", .{err});
                    continue;
                };
                const name = try f.alloc.dupe(u8, tag_name);
                errdefer f.alloc.free(name);
                const tag: Git.Tag = Git.Tag.fromObject(obj, name) catch continue;
                tags.append(f.alloc, tag) catch return error.ServerFault;
            },
            else => |_, t| log.debug("lol ignoring {}", .{t}),
        }
    }

    Git.Tag.sortNewest(&tags);
    var tstack: std.ArrayList(S.RepoTagsHtml.Tags) = .empty;
    for (tags.items) |tag| {
        try tstack.append(f.alloc, .{ .name = .abx(tag.name) });
    }

    const count = rd.deltaCount(f);
    //const open_graph: S.OpenGraph = .{ .title = rd.name, .desc = page_desc orelse "" };
    const repo_header: S.BaseRepoHeaderHtml = .{
        .git_uri = .{
            .host = .safe(try (f.request.host orelse return error.DataMissing).valid()),
            .repo_name = .abx(rd.name),
        },
        .repo_name = .safe(rd.name),
        .description = .abx(repo.description(f.alloc, f.io) catch ""),
        .upstream = if (repo.findRemote("upstream")) |up| .{
            .href = .abx(try allocPrint(f.alloc, "{f}", .{std.fmt.alt(up, .formatLink)})),
        } else null,
        .blame = null,
        .issue_count = count.issue,
        .diff_count = count.diff,
    };

    var page = TagPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = f.template_data.get(S.BodyHeaderHtml).?.*,
        .repo_header = repo_header,
        .tags = tstack.items,
    });

    try f.sendPage(&page);
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
const log = std.log.scoped(.endpoint_tags);
const Repo = @import("../../Repo.zig");
const Git = @import("../../git.zig");
