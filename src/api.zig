const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Verse = @import("verse");
pub const Router = Verse.Router;

const ROUTE = Router.ROUTE;

const Repo = @import("api/repo.zig");

const endpoints = [_]Router.Match{
    ROUTE("v0", router),
    ROUTE("v1", router),

    ROUTE("diff", diff),
    ROUTE("heartbeat", heartbeat),
    ROUTE("issue", issue),
    ROUTE("network", router),
    ROUTE("patch", diff),
    ROUTE("repo", Repo.router),
    ROUTE("user", user),
};

const APIRouteData = struct {
    alloc: Allocator,
    version: usize = 0,

    pub fn init(a: Allocator) !*APIRouteData {
        const rd = try a.create(APIRouteData);
        rd.* = .{
            .alloc = a,
        };
        return rd;
    }
};

pub fn router(vrs: *Verse) Router.RoutingError!Router.BuildFn {
    const uri_api = vrs.uri.next() orelse return heartbeat;
    if (!std.mem.eql(u8, uri_api, "api")) return heartbeat;
    const rd = APIRouteData.init(vrs.alloc) catch @panic("OOM");
    vrs.route_data.add("api", rd) catch unreachable;

    return Router.router(vrs, &endpoints);
}

const Diff = struct {
    sha: []const u8,
};

fn diff(vrs: *Verse) Router.Error!void {
    return try vrs.sendJSON([0]Diff{}, .ok);
}

const HeartBeat = struct {
    nice: usize = 0,
};

fn heartbeat(vrs: *Verse) Router.Error!void {
    return try vrs.sendJSON(HeartBeat{ .nice = 69 }, .ok);
}

const Issue = struct {
    index: usize,
};

fn issue(vrs: *Verse) Router.Error!void {
    return try vrs.sendJSON([0]Issue{}, .ok);
}

/// Likely to be renamed
const RemotePeer = struct {
    name: []const u8,
    uri: []const u8,
    count: usize,
    /// The last time this peer was was sync'd
    updated: usize,
    /// The last time this peer changed
    changed: usize,
};

const Network = struct {
    networks: []RemotePeer,
};

fn network(vrs: *Verse) Router.Error!void {
    return try vrs.sendJSON(Network{ .networks = [0].{} }, .ok);
}

const Patch = struct {
    patch: []const u8,
};

fn patch(vrs: *Verse) Router.Error!void {
    return try vrs.sendJSON(Patch{ .patch = [0].{} }, .ok);
}

const Flex = struct {
    days: []const Day,

    pub const Day = struct {
        epoch: usize = 0,
    };
};

fn flex(vrs: *Verse) Router.Error!void {
    return try vrs.sendJSON([0]Flex{}, .ok);
}

const User = struct {
    name: []const u8,
    email: []const u8,
};

fn user(vrs: *Verse) Router.Error!void {
    return try vrs.sendJSON([0]User{}, .ok);
}
