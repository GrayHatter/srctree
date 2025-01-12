const std = @import("std");
const eql = std.mem.eql;
const verse = @import("verse");
const Frame = verse.Frame;

const Router = verse.Router;
const Template = verse.template;
const S = Template.Structs;
const Api = @import("api.zig");

const ROUTE = Router.ROUTE;
const GET = Router.GET;
const STATIC = Router.STATIC;
const Match = Router.Match;
const BuildFn = Router.BuildFn;

const commitFlex = @import("endpoints/commit-flex.zig").commitFlex;

const Repo = @import("endpoints/repos.zig");
const Admin = @import("endpoints/admin.zig");
const Search = @import("endpoints/search.zig");
const Settings = @import("endpoints/settings.zig");
const Gist = @import("endpoints/gist.zig");

pub const routes = [_]Match{
    //GET("", commitFlex),
    ROUTE("admin", &Admin.endpoints),
    ROUTE("api", Api.router),
    GET("debug", debug),
    ROUTE("gist", Gist.router),
    ROUTE("inbox", Search.router),
    ROUTE("repo", Repo.router),
    ROUTE("repos", Repo.router),
    ROUTE("search", &Search.router),
    ROUTE("settings", &Settings.endpoints),
    //ROUTE("todo", USERS.todo),
    ROUTE("user", commitFlex),
    STATIC("static"),
};

const endpoints = verse.Endpoints(.{
    struct {
        pub const verse_name = .root;
        pub const verse_routes = routes;
        pub const verse_builder = &builder;
        pub const index = commitFlex;
    },
    @import("endpoints/network.zig"),
});

const E404Page = Template.PageData("4XX.html");

fn notFound(vrs: *Frame) Router.Error!void {
    std.debug.print("404 for route\n", .{});
    vrs.status = .not_found;
    var page = E404Page.init(.{});
    vrs.sendPage(&page) catch unreachable;
}

pub const router = endpoints.router;

pub const router2 = Router{
    .routefn = srouter,
    .builderfn = builder,
    .routerfn = defaultRouter,
};

pub fn srouter(vrs: *Frame) Router.RoutingError!BuildFn {
    return Router.router(vrs, &routes);
}

pub fn defaultRouter(frm: *Frame, rt: Router.RouteFn) BuildFn {
    return rt(frm) catch |err| switch (err) {
        error.MethodNotAllowed => notFound,
        error.NotFound => notFound,
        error.Unrouteable => notFound,
    };
}

fn debug(_: *Frame) Router.Error!void {
    return error.Abusive;
}

pub fn builder(vrs: *Frame, call: BuildFn) void {
    const btns = [1]Template.Structs.NavButtons{.{ .name = "inbox", .extra = 0, .url = "/inbox" }};
    var bh: S.BodyHeaderHtml = vrs.response_data.get(S.BodyHeaderHtml) catch .{ .nav = .{
        .nav_auth = "Error",
        .nav_buttons = &btns,
    } };

    bh.nav.nav_auth = if (vrs.user) |usr| n: {
        break :n if (usr.username) |un| un else "Error No Username";
    } else "Public";
    vrs.response_data.add(bh) catch {};
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
