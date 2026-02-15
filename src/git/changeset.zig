name: []const u8,
sha: Sha,
title: []const u8,
timestamp: i64,

const ChangeSet = @This();

pub fn init(a: Allocator, name: []const u8, commit: Commit) !ChangeSet {
    return ChangeSet{
        .name = try a.dupe(u8, name),
        .sha = commit.sha,
        .title = try a.dupe(u8, trim(u8, commit.title, " \n")),
        .timestamp = commit.committer.timestamp,
    };
}

pub fn raze(cs: ChangeSet, a: Allocator) void {
    a.free(cs.name);
    a.free(cs.title);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Commit = @import("Commit.zig");
const Sha = @import("Sha.zig");
const trim = std.mem.trim;
