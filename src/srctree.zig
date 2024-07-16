const Routes = @import("routes.zig");
const Context = @import("context.zig");
const Endpoint = @import("endpoint.zig");
const Template = @import("template.zig");
const Api = @import("api.zig");
const Types = @import("types.zig");

const ROUTE = Routes.ROUTE;
const Match = Routes.Match;
const Callable = Endpoint.Callable;
const allocPrint = @import("std").fmt.allocPrint;

pub const routes = [_]Match{
    ROUTE("admin", Endpoint.admin),
    ROUTE("api", Api.router),
    ROUTE("diffs", Endpoint.USERS.diffs),
    ROUTE("inbox", Endpoint.search),
    ROUTE("network", Endpoint.network),
    ROUTE("repo", Endpoint.repo),
    ROUTE("repos", Endpoint.repo),
    ROUTE("search", Endpoint.search),
    ROUTE("todo", Endpoint.USERS.todo),
    ROUTE("user", Endpoint.commitFlex),
};

fn unroutable(ctx: *Context) Routes.Error!void {
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
        Template.Context.initWith(ctx.alloc, &[3]Template.Context.Simple{
            .{ .name = "Name", .value = "inbox" },
            .{ .name = "Url", .value = "/inbox" },
            .{ .name = "Extra", .value = inboxcnt },
        }) catch return unroutable,
    }) catch return unroutable;

    ctx.putContext("Header.Nav", .{ .block = header_nav }) catch return unroutable;
    return Routes.router(ctx, &routes);
}
