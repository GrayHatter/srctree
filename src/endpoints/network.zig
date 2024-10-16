const std = @import("std");

const DOM = @import("../dom.zig");
const Context = @import("../context.zig");
const Template = @import("../template.zig");

const Route = @import("../routes.zig");
const Error = Route.Error;
const UriIter = Route.UriIter;
const HTML = @import("../html.zig");
const Repos = @import("../repos.zig");
const Ini = @import("../ini.zig");

const ROUTE = Route.ROUTE;

pub const endpoints = [_]Route.Match{
    ROUTE("", default),
};

fn default(ctx: *Context) Error!void {
    var dom = DOM.new(ctx.alloc);

    const list = try Repos.allNames(ctx.alloc);
    const cwd = std.fs.cwd();
    for (list) |reponame| {
        var b: [0x800]u8 = undefined;
        const confname = std.fmt.bufPrint(&b, "repos/{s}/", .{reponame}) catch unreachable;
        var rdir = cwd.openDir(confname, .{}) catch unreachable;
        defer rdir.close();
        const cffd = rdir.openFile("config", .{}) catch rdir.openFile(".git/config", .{}) catch continue;
        defer cffd.close();
        const conf = Ini.fromFile(ctx.alloc, cffd) catch unreachable;
        if (conf.get("remote \"upstream\"")) |ns| {
            if (ns.get("url")) |url| {
                const purl = try Repos.parseGitRemoteUrl(ctx.alloc, url);
                dom = dom.open(HTML.h3(null, &HTML.Attr.class("upstream")));
                dom.push(HTML.text("Upstream: "));
                dom.push(HTML.anch(purl, try HTML.Attr.create(ctx.alloc, "href", purl)));
                dom = dom.close();
            }
        }
    }

    const data = dom.done();

    var tmpl = Template.find("network.html");
    _ = ctx.addElements(ctx.alloc, "Netlist", data) catch unreachable;
    try ctx.sendTemplate(&tmpl);
}
