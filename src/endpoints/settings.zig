pub const Template = @import("../template.zig");
const Context = @import("../context.zig");
const Route = @import("../routes.zig");

pub const endpoints = [_]Route.Match{
    Route.GET("", default),
    Route.POST("post", post),
};

fn default(ctx: *Context) Route.Error!void {
    try ctx.request.auth.validOrError();
    var tmpl = Template.find("settings.html");
    tmpl.init(ctx.alloc);
    try ctx.sendTemplate(&tmpl);
}
fn post(ctx: *Context) Route.Error!void {
    _ = ctx;
}
