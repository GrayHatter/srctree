const std = @import("std");
const Allocator = std.mem.Allocator;
const routes = @import("routes.zig");
const ROUTE = routes.ROUTE;
const Context = @import("context.zig");

const endpoints = [_]routes.MatchRouter{
    ROUTE("v0", router),
    ROUTE("v1", router),

    ROUTE("diff", diff),
    ROUTE("heartbeat", heartbeat),
    ROUTE("issue", issue),
    ROUTE("network", router),
    ROUTE("patch", diff),
    ROUTE("repo", repo),
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

pub fn router(ctx: *Context) routes.Error!routes.Callable {
    const rd = try APIRouteData.init(ctx.alloc);
    ctx.route_ctx = rd;

    return heartbeat;
}

const Diff = struct {
    sha: []const u8,
};

fn diff(ctx: *Context) routes.Error!void {
    return try ctx.sendJSON([0]Diff{});
}

const HeartBeat = struct {
    nice: usize = 0,
};

fn heartbeat(ctx: *Context) routes.Error!void {
    return try ctx.sendJSON(HeartBeat{ .nice = 69 });
}

const Issue = struct {
    index: usize,
};

fn issue(ctx: *Context) routes.Error!void {
    return try ctx.sendJSON([0]Issue{});
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

fn network(ctx: *Context) routes.Error!void {
    return try ctx.sendJSON(Network{ .networks = [0].{} });
}

const Patch = struct {
    patch: []const u8,
};

fn patch(ctx: *Context) routes.Error!void {
    return try ctx.sendJSON(Patch{ .patch = [0].{} });
}

const Repo = struct {
    name: []const u8,
    head: []const u8,
    updated: []const u8,
};

fn repo(ctx: *Context) routes.Error!void {
    return try ctx.sendJSON([0]Repo{});
}

const Flex = struct {
    days: []const Day,

    pub const Day = struct {
        epoch: usize = 0,
    };
};

fn flex(ctx: *Context) routes.Error!void {
    return try ctx.sendJSON([0]Flex{});
}

const User = struct {
    name: []const u8,
    email: []const u8,
};

fn user(ctx: *Context) routes.Error!void {
    return try ctx.sendJSON([0]user{});
}
