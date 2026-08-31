alloc: Allocator,

const Cache = @This();
/// List of endpoint cache blobs, TODO abstract this to something good!
//list: struct {
//    const COMMIT_FLEX = @import("endpoints/commit-flex.zig").CACHED_MAP;
//    commit_flex: COMMIT_FLEX,
//},

/// Basically a thin wrapper around StringHashMap
pub fn Cacher(T: type) type {
    return struct {
        cache: StringHashMap(T),
    };
}

const commit_flex = @import("endpoints/commit-flex.zig");
const repos = @import("endpoints/repos.zig");
pub fn init(a: Allocator) Cache {
    commit_flex.initCache(a);
    repos.initCache(a);

    return .{
        .alloc = a,
    };
}

pub fn raze(c: Cache) void {
    commit_flex.razeCache(c.alloc);
    repos.razeCache(c.alloc);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
