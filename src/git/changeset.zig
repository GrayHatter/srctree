const std = @import("std");
const Allocator = std.mem.Allocator;

const SHA = @import("../git.zig").SHA;

pub const ChangeSet = @This();

alloc: Allocator,
name: []const u8,
sha: SHA,
// Index into commit slice
commit_title: []const u8,
commit: []const u8,
timestamp: i64,

pub fn init(a: Allocator, name: []const u8, sha: SHA, msg: []const u8, ts: i64) !ChangeSet {
    const commit = try a.dupe(u8, msg);
    return ChangeSet{
        .alloc = a,
        .name = try a.dupe(u8, name),
        .sha = sha,
        .commit = commit,
        .commit_title = if (std.mem.indexOf(u8, commit, "\n\n")) |i| commit[0..i] else commit,
        .timestamp = ts,
    };
}

pub fn raze(self: ChangeSet) void {
    self.alloc.free(self.name);
    self.alloc.free(self.commit);
}
