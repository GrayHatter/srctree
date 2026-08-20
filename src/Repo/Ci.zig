/// Aligned to Git.Repo for @fieldParentPtr
enabled: bool align(8) = false,
srctree: SrctreeConf = .empty,
conf_bytes: [:0]const u8 = &.{},
artifacts: Artifacts = .{},
cache: Cache = .{},
source: Source = .{},

const Ci = @This();

pub const SrctreeConf = struct {
    ci: ?[]const u8,
    docs: ?[]const u8,

    pub const empty: SrctreeConf = .{
        .ci = null,
        .docs = null,
    };
};

pub fn status(ci: *Ci, a: Allocator, io: Io) !bool {
    const repo: *Repo = @fieldParentPtr("ci", ci);
    ci.enabled = false;
    const commit = repo.git.HEAD(a, io) catch return false; // empty or broken repo
    defer commit.raze(a);
    const tree = try commit.loadTree(&repo.git, a, io);
    defer tree.raze(a);
    var itr = tree.iterate();
    while (itr.next()) |next| {
        if (eql(u8, next.name, "build.zig.zon")) {
            const blob = try repo.git.objects.load(next.sha, a, io);
            switch (blob) {
                .blob => if (find(u8, blob.blob.data.blob, ".srctree =")) |_| {
                    defer blob.blob.raze(a);
                    ci.conf_bytes = try a.dupeSentinel(u8, blob.blob.data.blob, 0);
                    ci.srctree = std.zon.parse.fromSliceAlloc(SrctreeConf, a, ci.conf_bytes, null, .{
                        .ignore_unknown_fields = true,
                    }) catch return false;

                    ci.enabled = true;
                    return ci.enabled;
                },
                else => {},
            }
        }
    }
    return ci.enabled;
}

pub fn run(ci: *Ci, a: Allocator, io: Io) !void {
    if (!ci.enabled) return error.Disabled;
    // load instructions
    try ci.validate(a, io);
    try ci.source.checkout(a, io);
    try ci.cache.inject(a, io);
    try ci.source.setup(a, io);
    try ci.source.tests(a, io);
    // save output
    ci.artifacts.save(a, io);
    try ci.cache.backup(a, io);
    try ci.source.raze(a, io);
}

pub fn raze(ci: *Ci, a: Allocator) void {
    a.free(ci.conf_bytes);
}

pub fn validate(ci: *Ci, a: Allocator, io: Io) !void {
    _ = ci;
    _ = a;
    _ = io;
    return error.NotImplemented;
}

pub const Artifacts = struct {
    pub fn save(art: *Artifacts, a: Allocator, io: Io) !void {
        _ = art;
        _ = a;
        _ = io;
        return error.NotImplemented;
    }
};

pub const Source = struct {
    pub fn checkout(src: *Source, a: Allocator, io: Io) !void {
        _ = src;
        _ = a;
        _ = io;
        return error.NotImplemented;
    }

    pub fn setup(src: *Source, a: Allocator, io: Io) !void {
        _ = src;
        _ = a;
        _ = io;
        return error.NotImplemented;
    }

    pub fn tests(src: *Source, a: Allocator, io: Io) !void {
        _ = src;
        _ = a;
        _ = io;
        return error.NotImplemented;
    }

    pub fn raze(src: *Source, a: Allocator, io: Io) !void {
        _ = src;
        _ = a;
        _ = io;
        return error.NotImplemented;
    }
};

pub const Cache = struct {
    pub fn inject(c: *Cache, a: Allocator, io: Io) !void {
        _ = c;
        _ = a;
        _ = io;
        return error.NotImplemented;
    }

    pub fn backup(c: *Cache, a: Allocator, io: Io) !void {
        _ = c;
        _ = a;
        _ = io;
        return error.NotImplemented;
    }
};

pub fn artifactsStore(ci: *Ci, a: Allocator, io: Io) !void {
    _ = ci;
    _ = a;
    _ = io;
    return error.NotImplemented;
}

const Repo = @import("../Repo.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const eql = std.mem.eql;
const find = std.mem.find;
const parseInt = std.fmt.parseInt;
