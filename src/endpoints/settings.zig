const std = @import("std");
pub const Template = @import("../template.zig");
const Context = @import("../context.zig");
const Route = @import("../routes.zig");
const UserData = @import("../request_data.zig").UserData;

pub const endpoints = [_]Route.Match{
    Route.GET("", default),
    Route.POST("post", post),
};

fn default(ctx: *Context) Route.Error!void {
    try ctx.request.auth.validOrError();
    var tmpl = Template.find("settings.html");

    var blocks = try ctx.alloc.alloc(Template.Context, ctx.cfg.?.ns.len);
    for (ctx.cfg.?.ns, 0..) |ns, i| {
        var ns_ctx = Template.Context.init(ctx.alloc);
        try ns_ctx.put("ConfigName", .{ .slice = ns.name });
        try ns_ctx.put("ConfigText", .{ .slice = ns.block });
        try ns_ctx.put("Count", .{ .slice = try std.fmt.allocPrint(
            ctx.alloc,
            "{}",
            .{std.mem.count(u8, ns.block, "\n") + 2},
        ) });

        blocks[i] = ns_ctx;
    }

    try ctx.putContext("ConfigBlocks", .{ .block = blocks });

    try ctx.sendTemplate(&tmpl);
}

const SettingsReq = struct {
    block_name: [][]const u8,
    block_text: [][]const u8,
};

fn post(ctx: *Context) Route.Error!void {
    try ctx.request.auth.validOrError();

    const udata = UserData(SettingsReq).initMap(ctx.alloc, ctx.req_data.post_data.?) catch return error.BadData;

    for (udata.block_name, udata.block_text) |name, text| {
        std.debug.print("block data:\nname '{s}'\ntext '''{s}'''\n", .{ name, text });
    }

    return ctx.response.redirect("/settings", true) catch unreachable;
}
