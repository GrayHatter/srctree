const std = @import("std");
const API = @import("../api.zig");
const Bleach = @import("../bleach.zig");
const Git = @import("../git.zig");

pub const Repo = struct {
    name: []const u8,
    head: []const u8,
    updated: []const u8,
};

pub const RepoRequest = struct {
    name: []const u8,
};

pub fn repo(ctx: *API.Context) API.Routes.Error!void {
    const req = try ctx.reqdata.validate(RepoRequest);

    const dname = try ctx.alloc.alloc(u8, req.name.len);
    const rname = Bleach.sanitize(req.name, dname, .{ .rules = .filename }) catch return error.BadData;
    if (!std.mem.eql(u8, req.name, rname)) return error.Abusive;

    var cwd = std.fs.cwd();
    const filename = try std.fmt.allocPrint(ctx.alloc, "./repos/{s}", .{rname});
    const dir = cwd.openDir(filename, .{}) catch {
        ctx.response.status = .not_found;
        return try ctx.sendJSON([0]Repo{});
    };
    var gitrepo = Git.Repo.init(dir) catch {
        ctx.response.status = .service_unavailable;
        return try ctx.sendJSON([0]Repo{});
    };
    gitrepo.loadData(ctx.alloc) catch return error.Unknown;
    defer gitrepo.raze(ctx.alloc);

    const head = switch (gitrepo.HEAD(ctx.alloc) catch return error.Unknown) {
        .branch => |b| b.sha,
        .sha => |s| s,
        else => return error.NotImplemented,
    };

    return try ctx.sendJSON([1]Repo{.{
        .name = rname,
        .head = head,
        .updated = "undefined",
    }});
}
