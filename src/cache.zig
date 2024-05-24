const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Cache = @This();

alloc: Allocator,

/// List of endpoint cache blobs, TODO abstract this to something good!
//list: struct {
//    const COMMIT_FLEX = @import("endpoints/commit-flex.zig").CACHED_MAP;
//    commit_flex: COMMIT_FLEX,
//},

const COMMIT_FLEX = @import("endpoints/commit-flex.zig");
pub fn init(a: Allocator) !Cache {
    COMMIT_FLEX.initCache(a);
    return .{
        .alloc = a,
    };
}

pub fn raze() void {
    COMMIT_FLEX.razeCache();
}
