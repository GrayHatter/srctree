pub const verse_name = .artifacts;

pub const verse_routes = [_]Router.Match{
    GET("list", list),
};

pub const index = list;

const ArtifactsHtml = T.PageData("repo/artifacts.html");

fn list(f: *Frame) Router.Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    const vis: repos.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo = (repos.open(rd.name, vis, f.io) catch return error.Unknown) orelse return error.Unrouteable;
    repo.loadData(f.alloc, f.io) catch return error.ServerFault;

    var page: ArtifactsHtml = .init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .nav = .{ .nav_buttons = &try RepoEndpoint.navButtons(f) } },
        .repo_header = .{
            .repo_name = rd.name,
            .description = try allocPrint(f.alloc, "{f}", .{
                abx.Html{ .text = repo.description(f.alloc, f.io) catch "" },
            }),
            .blame = null,
            .git_uri = null,
            .upstream = null,
        },
        .artifacts = &.{
            .{ .name = "name", .date = "date", .href = "href" },
        },
    });

    return f.sendPage(&page);
}

fn view(f: *Frame) Router.Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    _ = rd;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const allocPrint = std.fmt.allocPrint;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const find = std.mem.find;
const eql = std.mem.eql;
const findPos = std.mem.findPos;
const findScalarPos = std.mem.findScalarPos;
const countScalar = std.mem.countScalar;
const log = std.log.scoped(.repo_search);

const repos = @import("../../repos.zig");
const RepoEndpoint = @import("../repos.zig");
const RouteData = RepoEndpoint.RepoRouter;
const git = @import("../../git.zig");

const verse = @import("verse");
const T = verse.template;
const S = verse.template.Structs;
const abx = verse.abx;
const Frame = verse.Frame;
const Router = verse.Router;
const Match = Router.Match;
const GET = Router.GET;
