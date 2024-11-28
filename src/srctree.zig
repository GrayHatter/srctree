const Routes = @import("routes.zig");
const Context = @import("context.zig");
const Template = @import("template.zig");
const Api = @import("api.zig");
//const Types = @import("types.zig");

const ROUTE = Routes.ROUTE;
const GET = Routes.GET;
const STATIC = Routes.STATIC;
const Match = Routes.Match;
const Callable = Routes.Callable;

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

fn notFound(ctx: *Context) Routes.Error!void {
    // TODO fix this
    @import("std").debug.print("404 for route\n", .{});
    ctx.response.status = .not_found;
    var page = E404Page.init(.{});
    ctx.sendPage(&page) catch unreachable;
}

pub fn router(ctx: *Context) Callable {
    //    var i_count: usize = 0;
    //    var itr = Types.Delta.iterator(ctx.alloc, "");
    //    while (itr.next()) |it| {
    //        i_count += 1;
    //        it.raze(ctx.alloc);
    //    }

    return Routes.router(ctx, &routes);
}

// TODO replace with better API
pub fn build(ctx: *Context, call: Callable) Routes.Error!void {
    return call(ctx) catch |err| switch (err) {
        error.InvalidURI,
        error.Unrouteable,
        => notFound(ctx),
        else => return err,
    };
}
