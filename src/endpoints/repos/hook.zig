pub const verse_name = .hook;

pub const verse_routes = [_]Router.Match{
    GET("update", update),
};

const UpdateData = struct {
    ref: []const u8,
    oldrev: []const u8,
    newrev: []const u8,
};

pub const ZonConf = struct {
    srctree: ?struct {
        docs: ?[]const u8 = null,
        tagged: ?[]const u8 = null,
        nightly: ?[]const u8 = null,
    } = null,
};

pub const AfterParty = struct {
    invites: std.ArrayList(Invite),

    pub fn invite(party: *AfterParty, name: []const u8, ptr: *anyopaque) !void {
        std.debug.print("{s} invited to after party\n", .{name});
        _ = party;
        _ = ptr;
        //try party.invites.appendBounded(.{ .ptr = ptr });
    }

    pub const Invite = struct {
        name: []const u8 = &.{},
        ptr: *anyopaque,
    };
};

pub const CI = struct {
    name: []const u8,
};

var after_party: AfterParty = .{
    .invites = .empty,
};

fn update(f: *Frame) Router.Error!void {
    const rd = RouteData.init(f.uri) orelse return error.ServerFault;
    const vis: Repo.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo = (repos.open(rd.name, vis, f.io) catch return error.Unknown) orelse return error.ServerFault;
    repo.loadData(f.alloc, f.io) catch return error.ServerFault;

    const update_data = f.request.data.query.validate(UpdateData) catch return error.DataInvalid;
    const commit = repo.commit(.init(update_data.newrev), f.alloc, f.io) catch unreachable;
    const tree = commit.loadTree(&repo, f.alloc, f.io) catch unreachable;
    var blb: git.Blob = undefined;
    var itr = tree.iterate();
    while (itr.next()) |b| {
        blb = b;
        if (std.mem.eql(u8, blb.name, "build.zig.zon")) break;
        // TODO add ffs support
        //if (std.mem.eql(u8, blb.name, "build.ffs")) break;
    } else return f.sendHTML(.ok, "plz no 502");

    var resolve = repo.loadBlob(blb.sha, f.alloc, f.io) catch return error.ServerFault;
    if (!resolve.isFile()) return {};
    const data = try f.alloc.dupeSentinel(u8, resolve.data.?, 0);
    var diag: std.zon.parse.Diagnostics = .{};
    if (std.zon.parse.fromSliceAlloc(ZonConf, f.alloc, data, &diag, .{ .ignore_unknown_fields = true })) |zon| {
        if (zon.srctree) |srctree| {
            var ci: CI = .{ .name = &.{} };
            if (srctree.docs) |d| after_party.invite(d, &ci) catch unreachable;
            if (srctree.tagged) |t| after_party.invite(t, &ci) catch unreachable;
            if (srctree.nightly) |n| after_party.invite(n, &ci) catch unreachable;
        }
    } else |err| std.debug.print("err {}\n", .{err});

    return f.sendHTML(.ok, "plz no 502");
}

const std = @import("std");

const repos = @import("../../repos.zig");
const Repo = @import("../../Repo.zig");
const RepoEndpoint = @import("../repos.zig");
const RouteData = RepoEndpoint.RepoRouter;
const git = @import("../../git.zig");

const verse = @import("verse");
const Frame = verse.Frame;
const Router = verse.Router;
const Match = Router.Match;
const GET = Router.GET;
