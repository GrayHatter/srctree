const std = @import("std");
pub const Template = @import("../template.zig");
const Context = @import("../context.zig");
const Route = @import("../routes.zig");
const RequestData = @import("../request_data.zig").RequestData;

pub const endpoints = [_]Route.Match{
    Route.GET("", default),
    Route.POST("post", post),
};

const SettingsPage = Template.PageData("settings.html");

fn default(ctx: *Context) Route.Error!void {
    try ctx.request.auth.validOrError();

    var blocks = try ctx.alloc.alloc(Template.Structs.ConfigBlocks, ctx.cfg.?.ns.len);
    for (ctx.cfg.?.ns, 0..) |ns, i| {
        blocks[i] = .{
            .config_name = ns.name,
            .config_text = ns.block,
            .count = try std.fmt.allocPrint(
                ctx.alloc,
                "{}",
                .{std.mem.count(u8, ns.block, "\n") + 2},
            ),
        };
    }

    const btns = [1]Template.Structs.NavButtons{.{ .name = "inbox", .extra = 0, .url = "/inbox" }};
    var page = SettingsPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .nav = .{ .nav_auth = undefined, .nav_buttons = &btns } },
        .config_blocks = blocks[0..],
    });

    try ctx.sendPage(&page);
}

const SettingsReq = struct {
    block_name: [][]const u8,
    block_text: [][]const u8,
};

fn post(ctx: *Context) Route.Error!void {
    try ctx.request.auth.validOrError();

    const udata = RequestData(SettingsReq).initMap(ctx.alloc, ctx.reqdata) catch return error.BadData;

    for (udata.block_name, udata.block_text) |name, text| {
        std.debug.print("block data:\nname '{s}'\ntext '''{s}'''\n", .{ name, text });
    }

    return ctx.response.redirect("/settings", true) catch unreachable;
}
