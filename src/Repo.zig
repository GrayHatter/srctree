name: ?[]const u8 = null,
git: Git.Repo,
pinned: bool,
ci: RepoCi = .{},

const Repo = @This();

pub const Agent = @import("Repo/Agent.zig");

pub const RepoCi = struct {
    // Aligned to Git.Repo for @fieldParentPtr
    enabled: bool align(8) = false,
    srctree: SrctreeConf = .empty,
    conf_bytes: [:0]const u8 = &.{},

    pub const SrctreeConf = struct {
        ci: ?[]const u8,
        docs: ?[]const u8,

        pub const empty: SrctreeConf = .{
            .ci = null,
            .docs = null,
        };
    };

    pub fn status(ci: *RepoCi, a: Allocator, io: Io) !bool {
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

    pub fn run(ci: *RepoCi, a: Allocator, io: Io) !void {
        if (!ci.enabled) return error.Disabled;
        var agent: Agent = .init(a, io);
        defer agent.raze();
    }

    pub fn raze(ci: *RepoCi, a: Allocator) void {
        a.free(ci.conf_bytes);
    }
};

pub fn init(name: ?[]const u8, rdir: Io.Dir, io: Io) !Repo {
    var git = try Git.Repo.init(rdir, io);
    var local: [8192]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&local);
    try git.loadConfig(fba.allocator(), io);
    defer git.config = null;
    defer git.config_ini = null;

    var pinned = false;
    if (git.config.?.srctree) |s| {
        if (s.pinned) |p| {
            pinned = p;
        }
    }
    return .{
        .name = name,
        .git = git,
        .pinned = pinned,
    };
}

pub fn raze(r: *Repo, a: Allocator, io: Io) void {
    r.git.raze(a, io);
}

pub const Sort = struct {
    alloc: Allocator,
    io: Io,
    by: By = .commit,

    pub const By = enum { commit, tag };

    pub fn sort(list: *ArrayList(Repo), a: Allocator, io: Io, by: By) void {
        std.sort.heap(Repo, list.items, Sort{ .alloc = a, .io = io, .by = by }, Sort.notLessThan);
    }

    // TODO deep invert this logic
    pub fn lessThan(ctx: Sort, l: Repo, r: Repo) bool {
        if (byPinned(l, r)) |pinned| return !pinned;

        switch (ctx.by) {
            .commit => return commitSorter(ctx, l, r),
            .tag => {
                var tags_left: std.ArrayList(Git.Tag) = .empty;
                for (l.git.refs.map.keys(), l.git.refs.map.values()) |name, ref| switch (ref) {
                    .tag => tags_left.append(ctx.alloc, Git.Tag.fromObject(
                        l.git.objects.load(ref.resolve(&l.git) catch continue, ctx.alloc, ctx.io) catch continue,
                        ctx.alloc.dupe(u8, name) catch unreachable,
                    ) catch continue) catch unreachable,
                    else => {},
                };

                var tags_right: std.ArrayList(Git.Tag) = .empty;
                for (r.git.refs.map.keys(), r.git.refs.map.values()) |name, ref| switch (ref) {
                    .tag => tags_right.append(ctx.alloc, Git.Tag.fromObject(
                        r.git.objects.load(ref.resolve(&r.git) catch continue, ctx.alloc, ctx.io) catch continue,
                        ctx.alloc.dupe(u8, name) catch unreachable,
                    ) catch continue) catch unreachable,
                    else => {},
                };

                if (tags_left.items.len > 0 or tags_right.items.len > 0) {
                    if (tags_left.items.len == 0) return true;
                    if (tags_right.items.len == 0) return false;
                    Git.Tag.sortNewest(&tags_left);
                    Git.Tag.sortNewest(&tags_right);

                    if (tags_left.items[0].tagger.timestamp == tags_right.items[0].tagger.timestamp)
                        return commitSorter(ctx, l, r);
                    return tags_right.items[0].tagger.timestamp > tags_left.items[0].tagger.timestamp;
                    //} else return false;
                } else return true;
            },
        }
    }

    fn byPinned(l: Repo, r: Repo) ?bool {
        const left_pinned: bool = if (l.git.config) |cfg|
            if (cfg.srctree) |srctree| srctree.pinned orelse false else false
        else
            false;

        const right_pinned: bool = if (r.git.config) |cfg|
            if (cfg.srctree) |srctree| srctree.pinned orelse false else false
        else
            false;

        if (left_pinned == right_pinned) {
            return null;
        } else if (left_pinned) {
            return true;
        } else if (right_pinned) {
            return false;
        }
        return null;
    }

    pub fn notLessThan(ctx: Sort, l: Repo, r: Repo) bool {
        return !lessThan(ctx, l, r);
    }

    fn commitSorter(ctx: Sort, l: Repo, r: Repo) bool {
        var lc = l.git.HEAD(ctx.alloc, ctx.io) catch return true;
        defer lc.raze(ctx.alloc);
        var rc = r.git.HEAD(ctx.alloc, ctx.io) catch return false;
        defer rc.raze(ctx.alloc);
        return sorter({}, lc.committer.timestr, rc.committer.timestr);
    }

    fn sorter(_: void, l: []const u8, r: []const u8) bool {
        return std.mem.lessThan(u8, l, r);
    }

    const tags = @import("endpoints/repos/tags.zig");
};

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

    pub fn next(ri: *Iterator, io: Io) !?Repo {
        while (try ri.itr.next(io)) |file| {
            if (file.kind != .directory and file.kind != .sym_link) continue;
            if (file.name[0] == '.') continue;
            if (!Vis.fromConfig(file.name).isVisible(ri.vis)) continue;
            const rdir = ri.dir.openDir(io, file.name, .{}) catch continue;
            ri.current_name = file.name;
            //return try .init(try Git.Repo.init(rdir, io));
            return try .init(ri.current_name, rdir, io);
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

pub var dirs: Dirs = .{};

pub const Dirs = struct {
    public: ?[]const u8 = "./repos",
    private: ?[]const u8 = null,
    secret: ?[]const u8 = null,

    pub fn directory(rds: Dirs, vis: Visibility, io: Io) !std.Io.Dir {
        var cwd = std.Io.Dir.cwd();
        return cwd.openDir(io, switch (vis) {
            .public => rds.public orelse return error.NoDirectory,
            .private => rds.private orelse return error.NoDirectory,
            .secret => rds.secret orelse return error.NoDirectory,
            .unlisted => rds.secret orelse return error.NoDirectory,
        }, .{ .iterate = true });
    }
};

pub fn exists(name: []const u8, vis: Visibility.Select, io: Io) bool {
    // TODO skips non-public dirs
    var dir = dirs.directory(.public, io) catch return false;
    defer dir.close(io);
    var itr = dir.iterate();
    while (itr.next(io) catch return false) |file| {
        if (file.kind != .directory and file.kind != .sym_link) continue;
        if (eql(u8, file.name, name)) {
            // lol, crap, there's a side channel leak no matter where I put
            // this... given near zero thought I've decided this is the better
            // option
            if (!Vis.fromConfig(name).isVisible(vis)) return false;
            return true;
        }
    }
    return false;
}

pub fn containsName(name: []const u8) bool {
    return if (name.len > 0) true else false;
}

const Git = @import("git.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const eql = std.mem.eql;
const find = std.mem.find;
const parseInt = std.fmt.parseInt;
const global_config = &@import("Config.zig").global;
