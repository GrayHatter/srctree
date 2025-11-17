name: []const u8,
sha: SHA,

pub fn toCommit(self: Branch, repo: *const Repo, a: Allocator, io: std.Io) !Commit {
    switch (try repo.objects.load(self.sha, a, io)) {
        .commit => |c| return c,
        else => return error.NotACommit,
    }
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
