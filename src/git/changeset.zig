name: []const u8,
sha: SHA,
// Index into commit slice
commit_title: []const u8,
commit: []const u8,
timestamp: i64,

const ChangeSet = @This();

pub fn init(a: Allocator, name: []const u8, commit: Commit) !ChangeSet {
    const msg = try a.dupe(u8, commit.message);
    return ChangeSet{
        .name = try a.dupe(u8, name),
        .sha = commit.sha,
        .commit = msg,
        .commit_title = msg[0..commit.title.len],
        .timestamp = commit.committer.timestamp,
    };
}

pub fn raze(self: ChangeSet, a: Allocator) void {
    a.free(self.name);
    a.free(self.commit);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Commit = @import("Commit.zig");
const SHA = @import("SHA.zig");
