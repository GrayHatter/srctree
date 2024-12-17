const std = @import("std");
const Verse = @import("verse");
const Template = Verse.Template;
const S = Verse.Template.Structs;
const Router = Verse.Router;
const RequestData = Verse.RequestData.RequestData;
const global_ini = &@import("../main.zig").root_ini;

pub const endpoints = [_]Router.Match{
    Router.GET("", default),
    Router.POST("post", post),
};

const SettingsPage = Template.PageData("settings.html");

fn default(vrs: *Verse) Router.Error!void {
    try vrs.auth.requireValid();

    var blocks: []S.ConfigBlocks = &[0]S.ConfigBlocks{};

    if (global_ini.*) |cfg| {
        blocks = try vrs.alloc.alloc(Template.Structs.ConfigBlocks, cfg.ns.len);
        for (cfg.ns, 0..) |ns, i| {
            blocks[i] = .{
                .config_name = ns.name,
                .config_text = ns.block,
                .count = try std.fmt.allocPrint(
                    vrs.alloc,
                    "{}",
                    .{std.mem.count(u8, ns.block, "\n") + 2},
                ),
            };
        }
    }

    var page = SettingsPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = (vrs.route_data.get("body_header", *const S.BodyHeaderHtml) catch return error.Unknown).*,
        .config_blocks = blocks[0..],
    });

    try vrs.sendPage(&page);
}

const SettingsReq = struct {
    block_name: [][]const u8,
    block_text: [][]const u8,
};

fn post(vrs: *Verse) Router.Error!void {
    try vrs.auth.requireValid();

    const udata = RequestData(SettingsReq).initMap(vrs.alloc, vrs.reqdata) catch return error.BadData;

    for (udata.block_name, udata.block_text) |name, text| {
        std.debug.print("block data:\nname '{s}'\ntext '''{s}'''\n", .{ name, text });
    }

    return vrs.redirect("/settings", true) catch unreachable;
}
