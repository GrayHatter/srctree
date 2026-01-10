pub const verse_name = .search;

pub const verse_routes = [_]Router.Match{
    GET("search", searchRepo),
};

pub const index = searchRepo;

const SearchHtml = T.PageData("repo/search.html");

const SearchReq = struct {
    q: ?[]const u8,
};

fn searchRepo(f: *Frame) Router.Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;

    const udata = f.request.data.query.validate(SearchReq) catch return error.DataInvalid;
    const str: ?[]const u8, const safe_str = if (udata.q) |usr_str|
        .{ usr_str, try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = usr_str }}) }
    else
        .{ null, "" };

    const commits, const files = if (str) |s|
        .{ try searchCommits(s, f.alloc), try searchFiles(s, f.alloc) }
    else
        .{ &.{}, &.{} };

    var page: SearchHtml = .init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .nav = .{ .nav_buttons = &try RepoEndpoint.navButtons(f) } },
        .repo_header = .{ .blame = null, .git_uri = null, .repo_name = rd.name, .upstream = null },
        .search = safe_str,
        .commits = commits,
        .files = files,
    });

    return f.sendPage(&page);
}

fn searchCommits(str: []const u8, a: Allocator) ![]S.SearchHtml.Commits {
    const commits = [_]S.SearchHtml.Commits{.{ .title = str }};
    return try a.dupe(S.SearchHtml.Commits, &commits);
}

fn searchFiles(str: []const u8, a: Allocator) ![]S.SearchHtml.Files {
    const files = [_]S.SearchHtml.Files{.{ .filename = str }};
    return try a.dupe(S.SearchHtml.Files, &files);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;

const RepoEndpoint = @import("../repos.zig");
const RouteData = RepoEndpoint.RouteData;

const verse = @import("verse");
const T = verse.template;
const S = verse.template.Structs;
const abx = verse.abx;
const Frame = verse.Frame;
const Router = verse.Router;
const Match = Router.Match;
const GET = Router.GET;
