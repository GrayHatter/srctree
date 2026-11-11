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
    const rd = RouteData.init(f) orelse return error.ServerFault;

    var repo = Repo.open(rd.name, .public_only, f.io) catch unreachable;
    repo.git.loadData(f.alloc, f.io) catch unreachable;
    const head = repo.git.HEAD(f.alloc, f.io) catch unreachable;
    _ = repo.ci.status(f.alloc, f.io) catch unreachable;
    _ = repo.ci.prepare(f.io) catch unreachable;
    var results = repo.ci.run(&head, f.alloc, f.io) catch unreachable;
    defer results.raze();

    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };
    const body_header: S.BodyHeaderHtml = f.template_data.get(S.BodyHeaderHtml).?.*;

    const build, const tests, const docs = switch (results) {
        .saved => |saved| .{
            saved.steps.items[0].payload,
            saved.steps.items[1].payload,
            saved.steps.items[2].payload,
        },
        .active => |*active| .{
            active.build.err.written(),
            active.tests.err.written(),
            active.docs.err.written(),
        },
    };

    var page = BuildPage.init(.{
        .meta_head = meta_head,
        .body_header = body_header,
        .build_output = .safe(build),
        .test_output = .safe(tests),
        .docs_output = .safe(docs),
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
