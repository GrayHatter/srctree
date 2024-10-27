const Routes = @import("routes.zig");
const Context = @import("context.zig");
const Template = @import("template.zig");
const Api = @import("api.zig");
const Types = @import("types.zig");

const ROUTE = Routes.ROUTE;
const GET = Routes.GET;
const STATIC = Routes.STATIC;
const Match = Routes.Match;
const Callable = Routes.Callable;
const allocPrint = @import("std").fmt.allocPrint;

const commitFlex = @import("endpoints/commit-flex.zig").commitFlex;

const USERS = @import("endpoints/users.zig");

const Repo = @import("endpoints/repos.zig");

const ADMIN = @import("endpoints/admin.zig");
const admin = &ADMIN.endpoints;

const NETWORK = @import("endpoints/network.zig");
const network = &NETWORK.endpoints;

const SEARCH = @import("endpoints/search.zig");
const search = &SEARCH.router;

const settings = @import("endpoints/settings.zig");
const Gist = @import("endpoints/gist.zig");

pub const routes = [_]Match{
    GET("", commitFlex),
    ROUTE("admin", admin),
    ROUTE("api", Api.router),
    ROUTE("diffs", USERS.diffs),
    ROUTE("gist", Gist.router),
    ROUTE("inbox", search),
    ROUTE("network", network),
    ROUTE("repo", Repo.router),
    ROUTE("repos", Repo.router),
    ROUTE("search", search),
    ROUTE("settings", &settings.endpoints),
    ROUTE("todo", USERS.todo),
    ROUTE("user", commitFlex),
    STATIC("static"),
};

fn unroutable(ctx: *Context) Routes.Error!void {
    ctx.response.status = .not_found;
    var tmpl = Template.find("4XX.html");
    ctx.sendTemplate(&tmpl) catch unreachable;
}

fn notFound(ctx: *Context) Routes.Error!void {
    // TODO fix this
    @import("std").debug.print("404 for route\n", .{});
    ctx.response.status = .not_found;
    var tmpl = Template.find("4XX.html");
    ctx.sendTemplate(&tmpl) catch unreachable;
}

pub fn router(ctx: *Context) Callable {
    var i_count: usize = 0;
    var itr = Types.Delta.iterator(ctx.alloc, "");
    while (itr.next()) |it| {
        i_count += 1;
        it.raze(ctx.alloc);
    }

    const inboxcnt = allocPrint(ctx.alloc, "{}", .{i_count}) catch unreachable;
    const header_nav = ctx.alloc.dupe(Template.Context, &[1]Template.Context{
        Template.Context.initWith(ctx.alloc, &[3]Template.Context.Pair{
            .{ .name = "Name", .value = "inbox" },
            .{ .name = "Url", .value = "/inbox" },
            .{ .name = "Extra", .value = inboxcnt },
        }) catch return unroutable,
    }) catch return unroutable;

    ctx.putContext("NavButtons", .{ .block = header_nav }) catch return unroutable;
    return Routes.router(ctx, &routes);
}

// TODO replace with better API
pub fn build(ctx: *Context, call: Callable) Routes.Error!void {
    return call(ctx) catch |err| switch (err) {
        error.InvalidURI => notFound(ctx),
        else => return err,
    };
}
