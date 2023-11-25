const std = @import("std");

const DOM = Endpoint.DOM;
const Endpoint = @import("../endpoint.zig");
const Response = Endpoint.Response;
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;

const HTML = @import("../html.zig");
const Repos = @import("../repos.zig");
const Ini = @import("../ini.zig");

const GET = Endpoint.Router.Methods.GET;
const POST = Endpoint.Router.Methods.POST;

pub const endpoints = [_]Endpoint.Router.MatchRouter{
    .{ .name = "", .methods = GET, .match = .{ .call = default } },
};

fn default(r: *Response, _: *UriIter) Error!void {
    var dom = DOM.new(r.alloc);

    const list = try Repos.allNames(r.alloc);
    const cwd = std.fs.cwd();
    for (list) |reponame| {
        var b: [0x800]u8 = undefined;
        const confname = std.fmt.bufPrint(&b, "repos/{s}/", .{reponame}) catch unreachable;
        var rdir = cwd.openDir(confname, .{}) catch unreachable;
        defer rdir.close();
        const cffd = rdir.openFile("config", .{}) catch rdir.openFile(".git/config", .{}) catch continue;
        defer cffd.close();
        const conf = Ini.init(r.alloc, cffd) catch unreachable;
        if (conf.get("remote \"upstream\"")) |ns| {
            if (ns.get("url")) |url| {
                var purl = try Repos.parseGitRemoteUrl(r.alloc, url);
                dom = dom.open(HTML.h3(null, &HTML.Attr.class("upstream")));
                dom.push(HTML.text("Upstream: "));
                dom.push(HTML.anch(purl, try HTML.Attr.create(r.alloc, "href", purl)));
                dom = dom.close();
            }
        }
    }

    var data = dom.done();

    var tmpl = Template.find("network.html");
    tmpl.init(r.alloc);
    _ = tmpl.addElements(r.alloc, "netlist", data) catch unreachable;
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;
    r.start() catch return Error.Unknown;
    r.send(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}
