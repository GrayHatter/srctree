const std = @import("std");
const Allocator = std.mem.Allocator;

const API = @import("../api.zig");
const Bleach = @import("../bleach.zig");
const Git = @import("../git.zig");
const Routes = @import("../routes.zig");

const ROUTE = Routes.ROUTE;

const endpoints = [_]Routes.Match{
    ROUTE("", repo),
    ROUTE("branches", repoBranches),
    ROUTE("tags", repoTags),
};

pub fn router(ctx: *API.Context) Routes.Error!Routes.Callable {
    const uri_api = ctx.uri.next() orelse return repo;
    if (!std.mem.eql(u8, uri_api, "repo")) return repo;

    return Routes.router(ctx, &endpoints);
}

pub const Repo = struct {
    name: []const u8,
    head: []const u8,
    updated: []const u8,
};

pub const RepoRequest = struct {
    name: []const u8,
};

fn openRepo(a: Allocator, raw_name: []const u8) !Git.Repo {
    const dname = try a.alloc(u8, raw_name.len);
    const rname = Bleach.sanitize(raw_name, dname, .{ .rules = .filename }) catch return error.InvalidName;
    if (!std.mem.eql(u8, raw_name, rname)) return error.InvalidName;

    var cwd = std.fs.cwd();
    const filename = try std.fmt.allocPrint(a, "./repos/{s}", .{rname});
    defer a.free(filename);
    const dir = try cwd.openDir(filename, .{});
    var gitrepo = try Git.Repo.init(dir);
    try gitrepo.loadData(a);
    return gitrepo;
}

pub fn repo(ctx: *API.Context) API.Routes.Error!void {
    const req = try ctx.reqdata.validate(RepoRequest);

    var gitrepo = openRepo(ctx.alloc, req.name) catch |err| switch (err) {
        error.InvalidName => return error.Abusive,
        error.FileNotFound => {
            ctx.response.status = .not_found;
            return try ctx.sendJSON([0]Repo{});
        },
        else => {
            ctx.response.status = .service_unavailable;
            return try ctx.sendJSON([0]Repo{});
        },
    };
    defer gitrepo.raze();

    const head = switch (gitrepo.HEAD(ctx.alloc) catch return error.Unknown) {
        .branch => |b| b.sha,
        .sha => |s| s,
        else => return error.NotImplemented,
    };

    return try ctx.sendJSON([1]Repo{.{
        .name = req.name,
        .head = head.hex[0..],
        .updated = "undefined",
    }});
}

pub const RepoBranches = struct {
    pub const Branch = struct {
        name: []const u8,
        hash: [40]u8,
    };
    name: []const u8,
    updated: []const u8,
    branches: []const Branch,
};

pub fn repoBranches(ctx: *API.Context) API.Routes.Error!void {
    const req = try ctx.reqdata.validate(RepoRequest);

    var gitrepo = openRepo(ctx.alloc, req.name) catch |err| switch (err) {
        error.InvalidName => return error.Abusive,
        error.FileNotFound => {
            ctx.response.status = .not_found;
            return try ctx.sendJSON([0]RepoBranches{});
        },
        else => {
            ctx.response.status = .service_unavailable;
            return try ctx.sendJSON([0]RepoBranches{});
        },
    };
    defer gitrepo.raze();

    const branches = try ctx.alloc.alloc(RepoBranches.Branch, gitrepo.branches.?.len);
    for (branches, gitrepo.branches.?) |*dst, src| {
        dst.* = .{
            .name = src.name,
            .hash = src.sha.hex,
        };
    }

    return try ctx.sendJSON([1]RepoBranches{.{
        .name = req.name,
        .updated = "undefined",
        .branches = branches[0..],
    }});
}

pub const RepoTags = struct {
    name: []const u8,
    updated: []const u8,
    tags: []const []const u8,
};

pub fn repoTags(ctx: *API.Context) API.Routes.Error!void {
    const req = try ctx.reqdata.validate(RepoRequest);

    var gitrepo = openRepo(ctx.alloc, req.name) catch |err| switch (err) {
        error.InvalidName => return error.Abusive,
        error.FileNotFound => {
            ctx.response.status = .not_found;
            return try ctx.sendJSON([0]RepoTags{});
        },
        else => {
            ctx.response.status = .service_unavailable;
            return try ctx.sendJSON([0]RepoTags{});
        },
    };
    gitrepo.loadData(ctx.alloc) catch return error.Unknown;
    defer gitrepo.raze();

    const repotags = gitrepo.tags orelse return try ctx.sendJSON([1]RepoTags{.{
        .name = req.name,
        .updated = "undefined",
        .tags = &.{},
    }});

    const tstack = try ctx.alloc.alloc([]const u8, repotags.len);

    for (repotags, tstack) |tag, *out| {
        out.* = tag.name;
    }
    return try ctx.sendJSON([1]RepoTags{.{
        .name = req.name,
        .updated = "undefined",
        .tags = tstack,
    }});
}
