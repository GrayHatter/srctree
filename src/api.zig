pub const verse_name = .api;

pub const verse_router = &router;

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

    pub fn init(a: Allocator) !APIRouteData {
        return .{
            .alloc = a,
        };
    }
};

pub fn router(vrs: *Frame) Router.RoutingError!Router.BuildFn {
    const uri_api = vrs.uri.next() orelse return heartbeat;
    if (!std.mem.eql(u8, uri_api, "api")) return heartbeat;
    const rd = APIRouteData.init(vrs.alloc) catch @panic("OOM");
    vrs.response_data.add(rd) catch unreachable;

    return Router.defaultRouter(vrs, &endpoints);
}

const Diff = struct {
    sha: []const u8,
};

fn diff(vrs: *Frame) Router.Error!void {
    return try vrs.sendJSON(.ok, [0]Diff{});
}

const HeartBeat = struct {
    nice: usize = 0,
};

fn heartbeat(vrs: *Frame) Router.Error!void {
    return try vrs.sendJSON(.ok, HeartBeat{ .nice = 69 });
}

const Issue = struct {
    index: usize,
};

fn issue(vrs: *Frame) Router.Error!void {
    return try vrs.sendJSON(.ok, [0]Issue{});
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

fn network(vrs: *Frame) Router.Error!void {
    return try vrs.sendJSON(.ok, Network{ .networks = [0].{} });
}

const Patch = struct {
    patch: []const u8,
};

fn patch(vrs: *Frame) Router.Error!void {
    return try vrs.sendJSON(.ok, Patch{ .patch = [0].{} });
}

const Flex = struct {
    days: []const Day,

    pub const Day = struct {
        epoch: usize = 0,
    };
};

fn flex(vrs: *Frame) Router.Error!void {
    return try vrs.sendJSON(.ok, [0]Flex{});
}

const User = struct {
    name: []const u8,
    email: []const u8,
};

fn user(vrs: *Frame) Router.Error!void {
    return try vrs.sendJSON(.ok, [0]User{});
}

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const verse = @import("verse");
const Frame = verse.Frame;
pub const Router = verse.Router;

const ROUTE = Router.ROUTE;

const Repo = @import("api/repo.zig");
