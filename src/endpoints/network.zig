pub const verse_name = .network;

const NetworkPage = template.PageData("network.html");

pub fn index(ctx: *Frame) Error!void {
    var dom = DOM.new(ctx.alloc);

    const list = try Repos.allNames(ctx.alloc);
    const cwd = std.fs.cwd();
    for (list) |reponame| {
        var b: [0x800]u8 = undefined;
        const confname = std.fmt.bufPrint(&b, "repos/{s}/", .{reponame}) catch continue;
        const rdir = cwd.openDir(confname, .{}) catch continue;
        var repo = Git.Repo.init(rdir) catch continue;
        repo.loadData(ctx.alloc) catch continue;
        defer repo.raze();
        if (repo.findRemote("upstream") catch continue) |remote| {
            if (remote.url) |_| {
                dom = dom.open(html.h3(null, &html.Attr.class("upstream")));
                dom.push(html.text("Upstream: "));
                const purl = try allocPrint(ctx.alloc, "{link}", .{remote});
                dom.push(html.anch(purl, try html.Attr.create(ctx.alloc, "href", purl)));
                dom = dom.close();
            }
        }
    }

    const data = dom.done();
    const htmllist = try ctx.alloc.alloc([]u8, data.len);
    for (htmllist, data) |*l, e| l.* = try std.fmt.allocPrint(ctx.alloc, "{}", .{e});
    const value = try std.mem.join(ctx.alloc, "", htmllist);

    const btns = [1]template.Structs.NavButtons{.{ .name = "inbox", .extra = 0, .url = "/inbox" }};
    var page = NetworkPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .nav = .{ .nav_buttons = &btns } },
        .netlist = value,
    });

    try ctx.sendPage(&page);
}

const std = @import("std");
const allocPrint = std.fmt.allocPrint;

const verse = @import("verse");
const Frame = verse.Frame;
const template = verse.template;
const html = template.html;
const DOM = html.DOM;

const Error = verse.Router.Error;
const Repos = @import("../repos.zig");
const Ini = @import("../ini.zig");
const Git = @import("../git.zig");
