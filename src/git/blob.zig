sha: Git.Sha,
mode: [6]u8,
name: []const u8,
data: union(enum) {
    blob: []u8,
    tree: Tree,
    unloaded: void,
} = .unloaded,

const Blob = @This();

pub fn init(sha: Sha, mode: [6]u8, name: []const u8, data: []u8) Blob {
    return if (mode[0] != 48) .{
        .sha = sha,
        .mode = mode,
        .name = name,
        .data = .{ .blob = data },
    } else .{
        .sha = sha,
        .mode = mode,
        .name = name,
        .data = .{ .tree = .init(sha, data) },
    };
}

pub fn toObject(self: Blob, a: Allocator, repo: Repo) !Object {
    if (!self.isFile()) return error.NotAFile;
    _ = a;
    _ = repo;
    return error.NotImplemented;
}

pub fn load(sha: Sha, repo: *const Repo, a: Allocator, io: Io) !Blob {
    return switch (try repo.objects.load(sha, a, io)) {
        .blob => |b| b,
        else => error.NotABlob,
    };
}

pub fn toTree(b: Blob, repo: *const Repo, a: Allocator, io: Io) !Tree {
    return switch (try repo.objects.load(b.sha, a, io)) {
        .tree => |t| t,
        else => error.NotATree,
    };
}

pub fn raze(self: Blob, a: Allocator) void {
    a.free(self.data.blob);
}

pub fn format(b: Blob, out: *Io.Writer) !void {
    try out.print("Blob{{ ", .{});
    switch (b.data) {
        .blob => try out.print("File", .{}),
        .tree => try out.print("Tree", .{}),
        .unloaded => try out.print("Unknown", .{}),
    }
    try out.print(" {s} @ {s} }}", .{ b.name, b.sha });
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Git = @import("../git.zig");
const Repo = Git.Repo;
const Object = Git.Object;
const Tree = @import("Tree.zig");
const Sha = @import("Sha.zig");
