name: []const u8,
sha: SHA,

pub fn toCommit(self: Branch, a: Allocator, repo: *const Repo) !Commit {
    switch (try repo.loadObject(a, self.sha)) {
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
