pub const verse_name = .network;

const NetworkPage = T.PageData("network.html");

pub fn index(f: *Frame) Error!void {
    var dom: *DOM = .create(f.alloc);

    const vis: Repo.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo_iter = Repo.iterateAll(vis, f.io) catch return error.Unknown;
    while (repo_iter.next(f.io) catch return error.Unknown) |repoC| {
        var repo = repoC;
        repo.git.loadData(f.alloc, f.io) catch |err| {
            log.err("Error, unable to load data on repo {s} {}", .{ repo_iter.current_name.?, err });
            continue;
        };
        defer repo.raze(f.alloc, f.io);
        repo.name = f.alloc.dupe(u8, repo_iter.current_name.?) catch null;

        if (repo.git.findRemote("upstream")) |remote| {
            if (remote.url) |_| {
                dom = dom.open(T.html.h3(&.{}, &.{.class("upstream")}));
                dom.push(T.html.text("Upstream: "));

                const purl = try allocPrint(f.alloc, "{f}", .{std.fmt.alt(remote, .formatLink)});
                dom.dupe(T.html.anch(&.{.text(purl)}, &.{.href(purl)}));
                dom = dom.close();
            }
        }
    }

    var html: std.Io.Writer.Allocating = .init(f.alloc);
    try dom.render(.compact, &html.writer);
    dom.raze();

    var page = NetworkPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = f.template_data.get(S.BodyHeaderHtml).?.*,
        .netlist = .safe(html.written()),
    });

    try f.sendPage(&page);
}

const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const log = std.log.scoped(.srctree);

const verse = @import("verse");
const Frame = verse.Frame;
const T = verse.template;
const S = T.Structs;
const DOM = T.html.DOM;

const Error = verse.Router.Error;
const Repo = @import("../Repo.zig");
const Ini = @import("../ini.zig");
const Git = @import("../git.zig");
