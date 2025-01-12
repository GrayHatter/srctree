pub const verse_name = .settings;

pub const verse_routes = [_]Router.Match{
    Router.POST("post", post),
};

const SettingsPage = template.PageData("settings.html");

pub fn index(vrs: *Frame) Router.Error!void {
    //try vrs.auth.requireValid();

    var blocks: []S.ConfigBlocks = &[0]S.ConfigBlocks{};

    if (global_ini.*) |cfg| {
        blocks = try vrs.alloc.alloc(S.ConfigBlocks, cfg.ns.len);
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
        .body_header = vrs.response_data.get(S.BodyHeaderHtml) catch return error.Unknown,
        .config_blocks = blocks[0..],
    });

    try vrs.sendPage(&page);
}

const SettingsReq = struct {
    block_name: [][]const u8,
    block_text: [][]const u8,
};

fn post(vrs: *Frame) Router.Error!void {
    //try vrs.auth.requireValid();

    const udata = RequestData(SettingsReq).initMap(vrs.alloc, vrs.request.data) catch return error.BadData;

    for (udata.block_name, udata.block_text) |name, text| {
        std.debug.print("block data:\nname '{s}'\ntext '''{s}'''\n", .{ name, text });
    }

    return vrs.redirect("/settings", .see_other) catch unreachable;
}

const std = @import("std");
const verse = @import("verse");
const Frame = verse.Frame;
const template = verse.template;
const S = template.Structs;
const Router = verse.Router;
const RequestData = verse.RequestData.RequestData;
const global_ini = &@import("../main.zig").root_ini;
