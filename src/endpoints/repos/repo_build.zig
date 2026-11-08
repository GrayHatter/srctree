pub const verse_name = .build;

pub const verse_router: Router.RouteFn = router;

pub const routes = [_]Router.Match{
    Router.ROUTE("", status),
};

pub const index = status;

const BuildPage = T.Page("build.html");

pub fn router(f: *Frame) Router.RoutingError!Router.BuildFn {
    const rd = RouteData.init(f) orelse return status;
    if (rd.verb != null and rd.verb.? == .commit)
        return status;
    return status;
}

fn status(f: *Frame) Error!void {
    _ = RouteData.init(f) orelse return error.ServerFault;
    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };
    const body_header: S.BodyHeaderHtml = f.template_data.get(S.BodyHeaderHtml).?.*;
    var page = BuildPage.init(.{
        .meta_head = meta_head,
        .body_header = body_header,
        .build_output = .safe("build status"),
    });

    try f.sendPage(&page);
}

const verse = @import("verse");
const Router = verse.Router;
const T = verse.template;
const S = T.Structs;
const Error = Router.Error;
const Frame = verse.Frame;
const Repo = @import("../../Repo.zig");
const repos = @import("../repos.zig");
const RouteData = repos.RouteData;
//const std = @import("std");
//const ArrayList = std.ArrayList;
//const Allocator = std.mem.Allocator;
//const Io = std.Io;
//const Reader = Io.Reader;
//const Writer = Io.Writer;
//const print = std.fmt.bufPrint;
//const endsWith = std.mem.endsWith;
//const eql = std.mem.eql;
//const find = std.mem.find;
//const trim = std.mem.trim;
//const abx = verse.Antibiotic;
//
//const Diffs = @import("diffs.zig");
//const Datetime = @import("../../DateTime.zig");
//const git = @import("../../git.zig");
//const Commit = git.Commit;
//const Sha = git.Sha;
//const syntax = @import("../../syntax.zig");
//const Humanize = @import("../../humanize.zig");
//const Patch = @import("../../Patch.zig");
//const delta_shared = @import("../delta.zig");
//const Types = @import("../../types.zig");
//const Delta = Types.Delta;
//const log = std.log.scoped(.srctree_build);
