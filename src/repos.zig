const repos = @This();

const DEBUG = false;
pub var dirs: RepoDirs = .{};

pub const RepoDirs = struct {
    public: ?[]const u8 = "./repos",
    private: ?[]const u8 = null,
    secret: ?[]const u8 = null,

    pub fn directory(rds: RepoDirs, vis: Visibility) !std.fs.Dir {
        var cwd = std.fs.cwd();
        return cwd.openDir(switch (vis) {
            .public => rds.public orelse return error.NoDirectory,
            .private => rds.private orelse return error.NoDirectory,
            .secret => rds.secret orelse return error.NoDirectory,
            .unlisted => rds.secret orelse return error.NoDirectory,
        }, .{ .iterate = true });
    }
};

pub const Visibility = enum {
    public,
    unlisted,
    private,
    secret,

    pub fn isVisible(v: Visibility, target: Visibility) bool {
        return switch (target) {
            .public => v == .public,
            .unlisted => v == .public or v == .unlisted,
            .private => v != .secret,
            .secret => true,
        };
    }

    pub const len = @typeInfo(Visibility).@"enum".fields.len;
};

/// public, but use with caution, might cause side channel leakage
pub fn visibility(name: []const u8) Visibility {
    if (global_config.repos) |crepos| {
        if (crepos.@"private-repos") |hr| {
            // if you actually use null, I hate you!
            var repo_itr = std.mem.tokenizeAny(u8, hr, "\x00|;, \t");
            while (repo_itr.next()) |r| {
                if (eql(u8, name, r))
                    return .private;
            }
        } else if (crepos.@"unlisted-repos") |hr| {
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

/// public, but use with caution, might cause side channel leakage
pub fn isHidden(name: []const u8) bool {
    return visibility(name) != .public;
}

pub fn exists(name: []const u8, vis: Visibility) bool {
    var dir = dirs.directory(vis) catch return false;
    defer dir.close();
    var itr = dir.iterate();
    while (itr.next() catch return false) |file| {
        if (file.kind != .directory and file.kind != .sym_link) continue;
        if (eql(u8, file.name, name)) {
            // lol, crap, there's a side channel leak no matter where I put
            // this... given near zero thought I've decided this is the better
            // option
            if (!visibility(name).isVisible(vis)) return false;
            return true;
        }
    }
    return false;
}

//pub fn open(name: []const u8, vis: Visability) !?Git.Repo {
//    if (isHiddenVis(name, vis)) return null;
//    return openAny(name);
//}
//
//pub fn openAny(name: []const u8) !?Git.Repo {

pub fn open(name: []const u8, vis: Visibility, io: Io) !?Git.Repo {
    if (!visibility(name).isVisible(vis)) return null;
    var root = try dirs.directory(vis);
    defer root.close();
    const dir = root.openDir(name, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir => return null,
        else => return err,
    };
    const dir2 = dir.adaptToNewApi();
    return try Git.Repo.init(dir2, io);
}

pub fn allNames(a: Allocator) !ArrayList([]u8) {
    var list: std.ArrayList([]u8) = .{};

    var dir_set = try dirs.directory(.public);
    defer dir_set.close();
    var itr_repo = dir_set.iterate();

    while (itr_repo.next() catch null) |dir| {
        if (dir.kind != .directory and dir.kind != .sym_link) continue;
        if (isHidden(dir.name)) continue;
        try list.append(a, try a.dupe(u8, dir.name));
    }
    return list;
}

pub const RepoIterator = struct {
    dir: std.fs.Dir,
    itr: std.fs.Dir.Iterator,
    vis: Visibility,
    /// only valid until the following call to next()
    current_name: ?[]const u8 = null,

    pub fn next(ri: *RepoIterator, io: Io) !?Git.Repo {
        while (try ri.itr.next()) |file| {
            if (file.kind != .directory and file.kind != .sym_link) continue;
            if (file.name[0] == '.') continue;
            if (!visibility(file.name).isVisible(ri.vis)) continue;
            const rdir = ri.dir.openDir(file.name, .{}) catch continue;
            ri.current_name = file.name;
            const rdir2 = rdir.adaptToNewApi();
            return try Git.Repo.init(rdir2, io);
        }
        ri.current_name = null;
        return null;
    }
};

pub fn allRepoIterator(vis: Visibility) !RepoIterator {
    const dir = try dirs.directory(vis);
    return .{
        .dir = dir,
        .itr = dir.iterate(),
        .vis = vis,
    };
}

pub fn containsName(name: []const u8) bool {
    return if (name.len > 0) true else false;
}

pub const Agent = struct {
    io: Io,
    config: Config,
    thread: ?std.Thread = null,
    enabled: bool = false,

    pub const Config = struct {
        enabled: bool,
        sleep_for: usize = 60 * 60 * SECONDS,
        upstream: Direction = .both,
        downstream: Direction = .both,
        skips: ?[]const u8,

        pub const Direction = packed struct(u2) {
            push: bool,
            pull: bool,

            pub const none: Direction = .{ .push = false, .pull = false };
            pub const push_only: Direction = .{ .push = true, .pull = false };
            pub const pull_only: Direction = .{ .push = false, .pull = true };
            pub const both: Direction = .{ .push = true, .pull = true };
        };

        const SECONDS = 1000 * 1000 * 1000;
    };

    const Updated = struct {
        upstream_push: i64 = 0,
        upstream_pull: i64 = 0,
        downstream_push: i64 = 0,
        downstream_pull: i64 = 0,

        pub fn format(u: Updated, w: *Writer) !void {
            try w.print(
                \\upstream_push {}
                \\upstream_pull {}
                \\downstream_push {}
                \\downstream_pull {}
                \\
            , .{ u.upstream_push, u.upstream_pull, u.downstream_push, u.downstream_pull });
        }
    };

    pub fn init(cfg: Config, io: Io) Agent {
        return .{
            .io = io,
            .config = cfg,
        };
    }

    pub fn startThread(a: *Agent) !void {
        if (a.config.enabled) {
            a.enabled = true;
            a.thread = try std.Thread.spawn(.{}, updateThread, .{a});
        }
    }

    pub fn joinThread(a: *Agent) void {
        a.enabled = false;
        if (a.thread) |thr| {
            thr.join();
        }
        a.thread = null;
    }

    fn setUpdated(dir: Io.Dir, update: Updated, io: Io) void {
        const file = dir.createFile(io, "srctree_sync", .{}) catch return;
        defer file.close(io);
        var old: fs.File = .adaptFromNewApi(file);
        var w_b: [1024]u8 = undefined;
        var writer = old.writer(&w_b);
        writer.interface.print("{f}", .{update}) catch return;
        writer.interface.flush() catch return;
    }

    fn getUpdated(dir: Io.Dir, io: Io) !Updated {
        var update: Updated = .{};
        var rbuf: [1024]u8 = undefined;
        const sync_str = dir.readFile(io, "srctree_sync", &rbuf) catch return .{};
        if (indexOf(u8, sync_str, "upstream_push ")) |i| {
            if (indexOfPos(u8, sync_str, i, "\n")) |j| {
                update.upstream_push = parseInt(i64, sync_str[i + 14 .. j], 10) catch 0;
            }
        }
        if (indexOf(u8, sync_str, "upstream_pull ")) |i| {
            if (indexOfPos(u8, sync_str, i, "\n")) |j| {
                update.upstream_pull = parseInt(i64, sync_str[i + 14 .. j], 10) catch 0;
            }
        }
        if (indexOf(u8, sync_str, "downstream_push ")) |i| {
            if (indexOfPos(u8, sync_str, i, "\n")) |j| {
                update.downstream_push = parseInt(i64, sync_str[i + 16 .. j], 10) catch 0;
            }
        }
        if (indexOf(u8, sync_str, "downstream_pull ")) |i| {
            if (indexOfPos(u8, sync_str, i, "\n")) |j| {
                update.downstream_pull = parseInt(i64, sync_str[i + 16 .. j], 10) catch 0;
            }
        }

        return update;
    }

    fn pullUpstream(name: []const u8, repo: *Git.Repo, a: Allocator, io: Io) !void {
        var update = try getUpdated(repo.dir, io);
        const rhead = try repo.HEAD(a, io);
        const head: []const u8 = switch (rhead) {
            .branch => |b| b.name[std.mem.lastIndexOf(u8, b.name, "/") orelse 0 ..][1..],
            .tag => |t| t.name,
            else => "main",
        };

        if (repo.findRemote("upstream")) |_| {
            var gitagent = repo.getAgent(a);
            if (gitagent.pullUpstream(head)) {
                log.debug("Update Successful on repo {s}", .{name});
            } else |err| switch (err) {
                error.NonAncestor => {},
                else => log.warn("Warning upstream pull failed repo {s} {}", .{ name, err }),
            }
            update.upstream_pull = (Io.Clock.now(.real, io) catch unreachable).toSeconds();
            setUpdated(repo.dir, update, io);
        } else log.debug("repo {s} doesn't have an upstream peer", .{name});
    }

    fn pushDownstream(name: []const u8, repo: *Git.Repo, a: Allocator, io: Io) !void {
        var update = try getUpdated(repo.dir, io);
        const repo_update = repo.updatedAt(a, io) catch 0;

        if (repo_update > update.downstream_push) {
            if (repo.findRemote("downstream")) |_| {
                var gitagent = repo.getAgent(a);
                const updated = gitagent.pushDownstream() catch er: {
                    log.warn("Warning, unable to push to downstream repo {s}", .{name});
                    break :er false;
                };
                update.downstream_push = (Io.Clock.now(.real, io) catch unreachable).toSeconds();
                setUpdated(repo.dir, update, io);
                if (!updated) log.warn("Warning downstream push failed repo {s}", .{name});
            } else log.debug("repo {s} doesn't have any downstream peers", .{name});
        } else {
            log.debug("Skipping for {s} no new branches {} {}", .{ name, repo_update, update.downstream_push });
        }
    }

    pub fn skipRepo(skips: []const u8, name: []const u8) bool {
        // if you actually use null, I hate you!
        var skippable = std.mem.tokenizeAny(u8, skips, "\x00|;, \t");
        while (skippable.next()) |skip| {
            if (eql(u8, skip, name))
                return true;
        } else return false;
    }

    pub fn updateThread(a: *Agent) void {
        const posix = std.posix;
        var sigset: posix.sigset_t = posix.sigemptyset();
        posix.sigaddset(&sigset, .INT);
        posix.sigprocmask(posix.SIG.BLOCK, &sigset, null);
        log.info("Spawning update thread", .{});
        // TODO past me is evil for doing this (replace with sane alloc source)
        const alloc = std.heap.page_allocator;
        var n_array = allNames(alloc) catch unreachable;
        // TODO drop skipped repos here
        const names = n_array.toOwnedSlice(alloc) catch unreachable;
        defer alloc.free(names);

        defer {
            for (names) |n| alloc.free(n);
            alloc.free(names);
        }

        a.io.sleep(.fromSeconds(20), .real) catch unreachable;
        running: while (a.enabled) {
            log.info("Starting sync for {} repos", .{names.len});
            for (names) |rname| {
                if (a.config.skips) |skips|
                    if (skipRepo(skips, rname)) continue;

                log.debug("starting update for {s}", .{rname});
                var repo: Git.Repo = open(rname, .public, a.io) catch {
                    log.warn("unable to load public repo {s}", .{rname});
                    continue;
                } orelse open(rname, .private, a.io) catch {
                    log.warn("unable to load private repo {s}", .{rname});
                    continue;
                } orelse {
                    log.warn("unable to find repo {s}", .{rname});
                    continue;
                };
                defer repo.raze(alloc, a.io);

                repo.loadData(alloc, a.io) catch {
                    log.err("Warning, unable to load data for repo {s}", .{rname});
                    continue;
                };

                if (a.config.upstream.pull) {
                    pullUpstream(rname, &repo, alloc, a.io) catch |err| {
                        log.err("Error ({}) when trying to pull on {s}\n", .{ err, rname });
                        break :running;
                    };
                }
                if (a.config.downstream.push) {
                    pushDownstream(rname, &repo, alloc, a.io) catch |err| {
                        log.err("Error ({}) when trying to push on {s}\n", .{ err, rname });
                        break :running;
                    };
                }
            }
            log.debug("update cycle complete", .{});
            var qi: usize = 60 * 60;
            while (qi > 0) {
                qi -|= 1;
                a.io.sleep(.fromSeconds(@intCast(a.config.sleep_for / 60 / 60)), .real) catch unreachable;
                if (!a.enabled) break :running;
            }
        }
        log.info("Update thread complete!", .{});
    }
};

const std = @import("std");
const log = std.log.scoped(.update_thread);
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;
const Io = std.Io;
const fs = std.fs;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const indexOfPos = std.mem.indexOfPos;
const parseInt = std.fmt.parseInt;

const Git = @import("git.zig");
const SrcConfig = @import("main.zig").SrcConfig;
const global_config = &@import("main.zig").global_config.config;
