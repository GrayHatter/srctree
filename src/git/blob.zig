const std = @import("std");
const Allocator = std.mem.Allocator;

const Git = @import("../git.zig");
const Repo = Git.Repo;
const Object = Git.Object;
const Tree = @import("tree.zig");

pub const Blob = @This();

mode: [6]u8,
name: []const u8,
hash: [40]u8,

pub fn isFile(self: Blob) bool {
    return self.mode[0] != 48;
}

pub fn toObject(self: Blob, a: Allocator, repo: Repo) !Object {
    if (!self.isFile()) return error.NotAFile;
    _ = a;
    _ = repo;
    return error.NotImplemented;
}

pub fn toTree(self: Blob, a: Allocator, repo: Repo) !Tree {
    if (self.isFile()) return error.NotATree;
    const tree = try Tree.fromRepo(a, repo, &self.hash);
    return tree;
}

pub fn format(self: Blob, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
    try out.print("Blob{{ ", .{});
    try if (self.isFile()) out.print("File", .{}) else out.print("Tree", .{});
    try out.print(" {s} @ {s} }}", .{ self.name, self.hash });
}
