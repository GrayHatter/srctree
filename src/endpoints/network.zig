const std = @import("std");
const allocPrint = std.fmt.allocPrint;

const DOM = @import("../dom.zig");
const Context = @import("../context.zig");
const Template = @import("../template.zig");

const Route = @import("../routes.zig");
const Error = Route.Error;
const UriIter = Route.UriIter;
const HTML = @import("../html.zig");
const Repos = @import("../repos.zig");
const Ini = @import("../ini.zig");
const Git = @import("../git.zig");

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
        const confname = std.fmt.bufPrint(&b, "repos/{s}/", .{reponame}) catch continue;
        const rdir = cwd.openDir(confname, .{}) catch continue;
        var repo = Git.Repo.init(rdir) catch continue;
        repo.loadData(ctx.alloc) catch continue;
        defer repo.raze();
        if (repo.findRemote("upstream") catch continue) |remote| {
            if (remote.url) |_| {
                dom = dom.open(HTML.h3(null, &HTML.Attr.class("upstream")));
                dom.push(HTML.text("Upstream: "));
                const purl = try allocPrint(ctx.alloc, "{link}", .{remote});
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
