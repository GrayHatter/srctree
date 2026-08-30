sha: Git.Sha,
mode: Git.Mode,
name: []const u8,
data: Object = .unloaded,

const Blob = @This();

pub const Object = union(enum) {
    blob: []u8,
    tree: Tree,
    unloaded: void,

    pub fn reload(o: *const Object, r: *const Repo, a: Allocator, io: Io) !Blob {
        const old: *const Blob = @fieldParentPtr("data", o);
        return Blob.load(old.sha, r, a, io) catch unreachable;
    }
};

pub fn init(sha: Sha, mode: Git.Mode, name: []const u8, data: ?[]u8) Blob {
    return .{
        .sha = sha,
        .mode = mode,
        .name = name,
        .data = if (data) |d|
            if (mode == .dir)
                .{ .tree = .init(sha, d) }
            else
                .{ .blob = d }
        else
            .unloaded,
    };
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
const Tree = @import("Tree.zig");
const Sha = @import("Sha.zig");
