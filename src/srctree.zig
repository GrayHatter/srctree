const std = @import("std");
const eql = std.mem.eql;
const Verse = @import("verse");
const Router = Verse.Router;
const Template = Verse.template;
const Api = @import("api.zig");
//const Types = @import("types.zig");

const ROUTE = Router.ROUTE;
const GET = Router.GET;
const STATIC = Router.STATIC;
const Match = Router.Match;
const BuildFn = Router.BuildFn;

const commitFlex = @import("endpoints/commit-flex.zig").commitFlex;

//const USERS = @import("endpoints/users.zig");
const Repo = @import("endpoints/repos.zig");
const Admin = @import("endpoints/admin.zig");
const Network = @import("endpoints/network.zig");
const Search = @import("endpoints/search.zig");
const Settings = @import("endpoints/settings.zig");
const Gist = @import("endpoints/gist.zig");

pub const routes = [_]Match{
    GET("", commitFlex),
    ROUTE("admin", &Admin.endpoints),
    ROUTE("api", Api.router),
    //ROUTE("diffs", USERS.diffs),
    GET("debug", debug),
    ROUTE("gist", Gist.router),
    ROUTE("inbox", Search.router),
    ROUTE("network", &Network.endpoints),
    ROUTE("repo", Repo.router),
    ROUTE("repos", Repo.router),
    ROUTE("search", &Search.router),
    ROUTE("settings", &Settings.endpoints),
    //ROUTE("todo", USERS.todo),
    ROUTE("user", commitFlex),
    STATIC("static"),
};

const E404Page = Template.PageData("4XX.html");

fn notFound(vrs: *Verse.Frame) Router.Error!void {
    std.debug.print("404 for route\n", .{});
    vrs.status = .not_found;
    var page = E404Page.init(.{});
    vrs.sendPage(&page) catch unreachable;
}

pub fn router(vrs: *Verse.Frame) Router.RoutingError!BuildFn {
    //    var i_count: usize = 0;
    //    var itr = Types.Delta.iterator(vrs.alloc, "");
    //    while (itr.next()) |it| {
    //        i_count += 1;
    //        it.raze(vrs.alloc);
    //    }
    return Router.router(vrs, &routes);
}

fn debug(_: *Verse.Frame) Router.Error!void {
    return error.Abusive;
}

pub fn builder(vrs: *Verse.Frame, call: BuildFn) void {
    const bh = vrs.alloc.create(Template.Structs.BodyHeaderHtml) catch unreachable;
    const btns = [1]Template.Structs.NavButtons{.{ .name = "inbox", .extra = 0, .url = "/inbox" }};
    bh.* = .{ .nav = .{ .nav_auth = "Public2", .nav_buttons = &btns } };
    vrs.route_data.add("body_header", bh) catch {};
    return call(vrs) catch |err| switch (err) {
        error.InvalidURI => builder(vrs, notFound), // TODO catch inline
        error.BrokenPipe => std.debug.print("client disconnect", .{}),
        error.IOWriteFailure => @panic("Unexpected IOWrite"),
        error.Unrouteable => {
            std.debug.print("Unrouteable", .{});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
        },
        error.NotImplemented,
        error.Unknown,
        error.OutOfMemory,
        error.NoSpaceLeft,
        => {
            std.debug.print("Unexpected error '{}'", .{err});
            @panic("not implemented");
        },
        error.Abusive,
        error.Unauthenticated,
        error.BadData,
        error.DataMissing,
        => {
            std.debug.print("Abusive {} because {}\n", .{ vrs.request, err });
            for (vrs.request.raw.zwsgi.vars) |vars| {
                std.debug.print("Abusive var '{s}' => '''{s}'''\n", .{ vars.key, vars.val });
            }
            if (vrs.request.data.post) |post_data| {
                std.debug.print("post data => '''{s}'''\n", .{post_data.rawpost});
            }
        },
    };
}
