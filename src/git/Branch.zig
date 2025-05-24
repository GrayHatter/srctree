name: []const u8,
sha: SHA,
repo: *const Repo,

pub fn toCommit(self: Branch, a: Allocator) !Commit {
    const obj = try self.repo.loadObject(a, self.sha);
    return Commit.initOwned(self.sha, a, obj);
}

pub fn raze(self: Branch, a: Allocator) void {
    a.free(self.name);
}

pub const Repo = @import("Repo.zig");
pub const Commit = @import("Commit.zig");
pub const SHA = @import("SHA.zig");
pub const Branch = @import("Branch.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
