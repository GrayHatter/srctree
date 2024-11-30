const Verse = @import("verse");
const Router = Verse.Router;
const Template = Verse.Template;
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

fn notFound(ctx: *Verse) Router.Error!void {
    // TODO fix this
    @import("std").debug.print("404 for route\n", .{});
    ctx.response.status = .not_found;
    var page = E404Page.init(.{});
    ctx.sendPage(&page) catch unreachable;
}

pub fn router(ctx: *Verse) Router.Error!BuildFn {
    //    var i_count: usize = 0;
    //    var itr = Types.Delta.iterator(ctx.alloc, "");
    //    while (itr.next()) |it| {
    //        i_count += 1;
    //        it.raze(ctx.alloc);
    //    }

    return Router.router(ctx, &routes);
}

// TODO replace with better API
pub fn build(ctx: *Verse, call: BuildFn) Router.Error!void {
    return call(ctx) catch |err| switch (err) {
        error.InvalidURI,
        error.Unrouteable,
        => notFound(ctx),
        else => return err,
    };
}
