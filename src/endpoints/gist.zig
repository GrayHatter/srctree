const Context = @import("../context.zig");
const Template = @import("../template.zig");

const Route = @import("../routes.zig");
const Error = Route.Error;
const POST = Route.POST;
const GET = Route.GET;

const endpoints = [_]Route.Match{
    GET("", view),
    GET("gist", view),
    POST("post", post),
};

pub fn router(ctx: *Context) Error!Route.Callable {
    return Route.router(ctx, &endpoints);
}

fn post(ctx: *Context) Error!void {
    var tmpl = Template.findTemplate("gist.html");
    return ctx.sendTemplate(&tmpl);
}

fn view(ctx: *Context) Error!void {
    const tmpl = Template.findTemplate("gist.html");
    const pgtype = Template.findPage("gist.html");
    const page = pgtype.init(tmpl, .{
        .meta_head = undefined,
        .body_header = undefined,
        .gist_body = "ha, it worked",
    });

    return ctx.sendPage(page);
}
