name: []const u8 = &.{},
git: Git.Repo,
ci: RepoCi = .{},

const Repo = @This();

pub const Agent = @import("Repo/Agent.zig");

pub var dirs: repos.Dirs = .{};

pub const RepoCi = struct {
    enabled: bool = false,
};

pub fn init(git: Git.Repo) !Repo {
    return .{ .git = git };
}

pub const Visibility = enum {
    public,
    unlisted,
    private,
    secret,

    pub const len = @typeInfo(Visibility).@"enum".fields.len;

    pub const Select = struct {
        pub const public_only: Select = .{ .public = true };
        pub const unlisted_only: Select = .{ .unlisted = true };
        pub const private_only: Select = .{ .private = true };
        pub const secret_only: Select = .{ .secret = true };
        pub const all: Select = .{ .public = true, .unlisted = true, .private = true, .secret = true };
        pub const default: Select = .public_only;

        public: bool = false,
        unlisted: bool = false,
        private: bool = false,
        secret: bool = false,
    };

    pub fn isVisible(v: Visibility, target: Select) bool {
        return switch (v) {
            .public => target.public,
            .unlisted => target.unlisted,
            .private => target.private,
            .secret => target.secret,
        };
    }

    /// public, but use with caution, might cause side channel leakage
    pub fn fromConfig(name: []const u8) Visibility {
        if (global_config.repos) |crepos| {
            if (crepos.private_repos) |hr| {
                // if you actually use null, I hate you!
                var repo_itr = std.mem.tokenizeAny(u8, hr, "\x00|;, \t");
                while (repo_itr.next()) |r| {
                    if (eql(u8, name, r))
                        return .private;
                }
            } else if (crepos.unlisted_repos) |hr| {
                // if you actually use null, I hate you!
                var repo_itr = std.mem.tokenizeAny(u8, hr, "\x00|;, \t");
                while (repo_itr.next()) |r| {
                    if (eql(u8, name, r))
                        return .unlisted;
                }
            }
        }
        return .public;
    }
};
const Vis = Visibility;

pub const Iterator = struct {
    dir: Io.Dir,
    itr: Io.Dir.Iterator,
    vis: Visibility.Select,
    /// only valid until the following call to next()
    current_name: ?[]const u8 = null,

    pub fn next(ri: *Iterator, io: Io) !?Git.Repo {
        while (try ri.itr.next(io)) |file| {
            if (file.kind != .directory and file.kind != .sym_link) continue;
            if (file.name[0] == '.') continue;
            if (!Vis.fromConfig(file.name).isVisible(ri.vis)) continue;
            const rdir = ri.dir.openDir(io, file.name, .{}) catch continue;
            ri.current_name = file.name;
            //return try .init(try Git.Repo.init(rdir, io));
            return try Git.Repo.init(rdir, io);
        }
        ri.current_name = null;
        ri.dir.close(io);
        return null;
    }
};

pub const allRepoIterator = iterateAll;

pub fn iterateAll(vis: Visibility.Select, io: Io) !Iterator {
    // TODO
    const dir = try dirs.directory(.public, io);
    return .{
        .dir = dir,
        .itr = dir.iterate(),
        .vis = vis,
    };
}

/// public, but use with caution, might cause side channel leakage
pub fn isHidden(name: []const u8) bool {
    return Vis.fromConfig(name) != .public;
}

pub fn allNames(a: Allocator, io: Io) !ArrayList([]u8) {
    var list: std.ArrayList([]u8) = .empty;

    var dir_set = try dirs.directory(.public, io);
    defer dir_set.close(io);
    var itr_repo = dir_set.iterate();

    while (itr_repo.next(io) catch null) |dir| {
        if (dir.kind != .directory and dir.kind != .sym_link) continue;
        if (isHidden(dir.name)) continue;
        try list.append(a, try a.dupe(u8, dir.name));
    }
    return list;
}

pub fn openGit(name: []const u8, vis: Vis.Select, io: Io) !?Git.Repo {
    if (!Vis.fromConfig(name).isVisible(vis)) return null;
    // TODO fromConfig may return the wrong dir
    //var root = try dirs.directory(Vis.fromConfig(name), io);
    var root = try dirs.directory(.public, io);
    defer root.close(io);
    const dir = root.openDir(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir => return null,
        else => return err,
    };
    return try Git.Repo.init(dir, io);
}

const Git = @import("git.zig");
const repos = @import("repos.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const eql = std.mem.eql;
const global_config = &@import("Config.zig").global;
