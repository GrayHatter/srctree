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

pub fn router(ctx: *Verse) Router.Error!Router.Callable {
    const uri_api = ctx.uri.next() orelse return heartbeat;
    if (!std.mem.eql(u8, uri_api, "api")) return heartbeat;
    const rd = try APIRouteData.init(ctx.alloc);
    ctx.route_ctx = rd;

    return Router.router(ctx, &endpoints);
}

const Diff = struct {
    sha: []const u8,
};

fn diff(ctx: *Verse) Router.Error!void {
    return try ctx.sendJSON([0]Diff{});
}

const HeartBeat = struct {
    nice: usize = 0,
};

fn heartbeat(ctx: *Verse) Router.Error!void {
    return try ctx.sendJSON(HeartBeat{ .nice = 69 });
}

const Issue = struct {
    index: usize,
};

fn issue(ctx: *Verse) Router.Error!void {
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

fn network(ctx: *Verse) Router.Error!void {
    return try ctx.sendJSON(Network{ .networks = [0].{} });
}

const Patch = struct {
    patch: []const u8,
};

fn patch(ctx: *Verse) Router.Error!void {
    return try ctx.sendJSON(Patch{ .patch = [0].{} });
}

const Flex = struct {
    days: []const Day,

    pub const Day = struct {
        epoch: usize = 0,
    };
};

fn flex(ctx: *Verse) Router.Error!void {
    return try ctx.sendJSON([0]Flex{});
}

const User = struct {
    name: []const u8,
    email: []const u8,
};

fn user(ctx: *Verse) Router.Error!void {
    return try ctx.sendJSON([0]User{});
}
