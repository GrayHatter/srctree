pub const verse_name = .artifacts;

pub const verse_routes = [_]Router.Match{
    GET("list", list),
};

pub const index = list;

const ArtifactsHtml = T.PageData("repo/artifacts.html");

fn list(f: *Frame) Router.Error!void {
    const rd = RouteData.init(f) orelse return error.NotFound;
    const vis: Repo.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo = (Repo.open(rd.name, vis, f.io) catch return error.ServerFault) orelse return error.NotFound;
    repo.git.loadData(f.alloc, f.io) catch return error.ServerFault;

    if (repo.ci.status(f.alloc, f.io) catch unreachable) {
        repo.ci.prepare(f.io) catch unreachable;
        var commit = repo.git.HEAD(f.alloc, f.io) catch unreachable;
        defer commit.raze(f.alloc);
        repo.ci.run(&commit, f.alloc, f.io) catch unreachable;
    }

    var page: ArtifactsHtml = .init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .nav = .{ .nav_buttons = &rd.navButtons(f) } },
        .repo_header = .{
            .repo_name = .abx(rd.name),
            .description = .abx(repo.git.description(f.alloc, f.io) catch ""),
            .blame = null,
            .git_uri = null,
            .upstream = null,
        },
        .artifacts = &.{.{
            .name = .safe("name"),
            .date = .safe("date"),
            .href = .abx("href"),
        }},
    });

    return f.sendPage(&page);
}

fn view(f: *Frame) Router.Error!void {
    const rd = RouteData.init(f) orelse return error.ServerFault;
    _ = rd;
}

const std = @import("std");
const Repo = @import("../../Repo.zig");
const RepoEndpoint = @import("../repos.zig");
const RouteData = RepoEndpoint.Router;
const verse = @import("verse");
const T = verse.template;
const Frame = verse.Frame;
const Router = verse.Router;
const GET = Router.GET;
