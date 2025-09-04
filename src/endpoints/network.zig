pub const verse_name = .network;

const NetworkPage = template.PageData("network.html");

pub fn index(ctx: *Frame) Error!void {
    var dom: *DOM = .create(ctx.alloc);

    var repo_iter = Repos.allRepoIterator(.public) catch return error.Unknown;
    while (repo_iter.next() catch return error.Unknown) |repoC| {
        var repo = repoC;
        repo.loadData(ctx.alloc) catch |err| {
            log.err("Error, unable to load data on repo {s} {}", .{ repo_iter.current_name.?, err });
            continue;
        };
        defer repo.raze();
        repo.repo_name = ctx.alloc.dupe(u8, repo_iter.current_name.?) catch null;

        if (repo.findRemote("upstream") catch continue) |remote| {
            if (remote.url) |_| {
                dom = dom.open(html.h3(null, &html.Attr.class("upstream")));
                dom.push(html.text("Upstream: "));
                const purl = try allocPrint(ctx.alloc, "{f}", .{std.fmt.alt(remote, .formatLink)});
                dom.push(html.anch(purl, try html.Attr.create(ctx.alloc, "href", purl)));
                dom = dom.close();
            }
        }
    }

    var page = NetworkPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = ctx.response_data.get(S.BodyHeaderHtml).?.*,
        .netlist = try dom.render(ctx.alloc, .compact),
    });

    try ctx.sendPage(&page);
}

const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const log = std.log.scoped(.srctree);

const verse = @import("verse");
const Frame = verse.Frame;
const template = verse.template;
const S = template.Structs;
const html = template.html;
const DOM = html.DOM;

const Error = verse.Router.Error;
const Repos = @import("../repos.zig");
const Ini = @import("../ini.zig");
const Git = @import("../git.zig");
