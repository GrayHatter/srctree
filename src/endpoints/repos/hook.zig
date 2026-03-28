pub const verse_name = .hook;

pub const verse_routes = [_]Router.Match{
    GET("update", update),
};

fn update(f: *Frame) Router.Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    const vis: repos.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo = (repos.open(rd.name, vis, f.io) catch return error.Unknown) orelse return error.Unrouteable;
    repo.loadData(f.alloc, f.io) catch return error.ServerFault;
}

const std = @import("std");

const repos = @import("../../repos.zig");
const RepoEndpoint = @import("../repos.zig");
const RouteData = RepoEndpoint.RepoRouter;
//const git = @import("../../git.zig");

const verse = @import("verse");
const Frame = verse.Frame;
const Router = verse.Router;
const Match = Router.Match;
const GET = Router.GET;
