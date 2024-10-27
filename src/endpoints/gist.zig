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
    const page_data = Template.PageData("gist.html");

    // TODO move this back into context somehow
    var btns = [1]Template.Structs.Navbuttons{
        .{
            .name = "inbox",
            .url = "/inbox",
        },
    };

    var page = page_data.init(tmpl, .{
        .meta_head = .{
            .open_graph = .{
                .title = "Create A New Gist",
            },
        },
        .body_header = .{
            .nav = .{
                .nav_auth = undefined,
                .nav_buttons = &btns,
            },
        },
        .gist_body = "ha, it worked",
    });

    return ctx.sendPage(&page);
}
