const repos = @This();

const DEBUG = false;
pub var dirs: RepoDirs = .{};

pub const RepoDirs = struct {
    public: ?[]const u8 = "./repos",
    private: ?[]const u8 = null,
    secret: ?[]const u8 = null,

    pub fn directory(rds: RepoDirs, vis: Visability) !std.fs.Dir {
        var cwd = std.fs.cwd();
        return cwd.openDir(switch (vis) {
            .public => rds.public orelse return error.NoDirectory,
            .private => rds.private orelse return error.NoDirectory,
            .secret => rds.secret orelse return error.NoDirectory,
        }, .{ .iterate = true });
    }
};

pub const Visability = enum {
    public,
    private,
    secret,

    pub const len = @typeInfo(Visability).@"enum".fields.len;
};

/// public, but use with caution, might cause side channel leakage
pub fn isHiddenVis(name: []const u8, vis: Visability) bool {
    if (global_config.repos) |crepos| {
        if (crepos.@"hidden-repos") |hr| {
            // if you actually use null, I hate you!
            var repo_itr = std.mem.tokenizeAny(u8, hr, "\x00|;, \t");
            while (repo_itr.next()) |r|
                if (eql(u8, name, r)) return switch (vis) {
                    .public => true,
                    .private => false,
                    .secret => @panic("not implemented"),
                };
        }
    }
    return false;
}

/// public, but use with caution, might cause side channel leakage
pub fn isHidden(name: []const u8) bool {
    return isHiddenVis(name, .public);
}

pub fn exists(name: []const u8, vis: Visability) bool {
    var dir = dirs.directory(vis) catch return false;
    defer dir.close();
    var itr = dir.iterate();
    while (itr.next() catch return false) |file| {
        if (file.kind != .directory and file.kind != .sym_link) continue;
        if (eql(u8, file.name, name)) {
            // lol, crap, there's a side channel leak no matter where I put
            // this... given near zero thought I've decided this is the better
            // option
            if (isHiddenVis(name, vis)) return false;
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

pub fn open(name: []const u8, vis: Visability) !?Git.Repo {
    if (isHiddenVis(name, vis)) return null;
    var root = try dirs.directory(vis);
    defer root.close();
    const dir = root.openDir(name, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.NotDir => return null,
        else => return err,
    };
    return try Git.Repo.init(dir);
}

pub fn allNames(a: Allocator) ![][]u8 {
    var list: std.ArrayList([]u8) = .{};

    var dir_set = try dirs.directory(.public);
    defer dir_set.close();
    var itr_repo = dir_set.iterate();

    while (itr_repo.next() catch null) |dir| {
        if (dir.kind != .directory and dir.kind != .sym_link) continue;
        if (isHidden(dir.name)) continue;
        try list.append(a, try a.dupe(u8, dir.name));
    }
    return try list.toOwnedSlice(a);
}

pub const RepoIterator = struct {
    dir: std.fs.Dir,
    itr: std.fs.Dir.Iterator,
    vis: Visability,
    /// only valid until the following call to next()
    current_name: ?[]const u8 = null,

    pub fn next(ri: *RepoIterator) !?Git.Repo {
        while (try ri.itr.next()) |file| {
            if (file.kind != .directory and file.kind != .sym_link) continue;
            if (file.name[0] == '.') continue;
            if (isHidden(file.name)) continue;
            const rdir = ri.dir.openDir(file.name, .{}) catch continue;
            ri.current_name = file.name;
            return try Git.Repo.init(rdir);
        }
        ri.current_name = null;
        return null;
    }
};

pub fn allRepoIterator(vis: Visability) !RepoIterator {
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
    config: Config,
    thread: ?std.Thread = null,
    enabled: bool = false,

    pub const Config = struct {
        enabled: bool,
        sleep_for: usize = 60 * 60 * SECONDS,
        upstream: Direction = .both,
        downstream: Direction = .both,

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

    pub fn init(cfg: Config) Agent {
        return .{
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

    fn setUpdated(dir: std.fs.Dir, update: Updated) void {
        var buffer: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{f}", .{update}) catch unreachable;
        dir.writeFile(.{ .sub_path = "srctree_sync", .data = text }) catch {};
    }

    fn getUpdated(dir: std.fs.Dir) !Updated {
        var update: Updated = .{};
        var rbuf: [1024]u8 = undefined;
        const sync_str = dir.readFile("srctree_sync", &rbuf) catch return .{};
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

    fn pullUpstream(a: Allocator, name: []const u8, repo: *Git.Repo) !void {
        var update = try getUpdated(repo.dir);
        const rhead = try repo.HEAD(a);
        const head: []const u8 = switch (rhead) {
            .branch => |b| b.name[std.mem.lastIndexOf(u8, b.name, "/") orelse 0 ..][1..],
            .tag => |t| t.name,
            else => "main",
        };

        if (try repo.findRemote("upstream")) |_| {
            var gitagent = repo.getAgent(a);
            if (gitagent.pullUpstream(head)) {
                log.debug("Update Successful on repo {s}", .{name});
            } else |err| switch (err) {
                error.NonAncestor => {},
                else => log.warn("Warning upstream pull failed repo {s} {}", .{ name, err }),
            }
            update.upstream_pull = std.time.timestamp();
            setUpdated(repo.dir, update);
        } else log.debug("repo {s} doesn't have an upstream peer", .{name});
    }

    fn pushDownstream(a: Allocator, name: []const u8, repo: *Git.Repo) !void {
        var update = try getUpdated(repo.dir);
        const repo_update = repo.updatedAt(a) catch 0;

        if (repo_update > update.downstream_push) {
            if (repo.findRemote("downstream") catch return) |_| {
                var gitagent = repo.getAgent(a);
                const updated = gitagent.pushDownstream() catch er: {
                    log.warn("Warning, unable to push to downstream repo {s}", .{name});
                    break :er false;
                };
                update.downstream_push = std.time.timestamp();
                setUpdated(repo.dir, update);
                if (!updated) log.warn("Warning downstream push failed repo {s}", .{name});
            } else log.debug("repo {s} doesn't have any downstream peers", .{name});
        } else {
            log.debug("Skipping for {s} no new branches {} {}", .{ name, repo_update, update.downstream_push });
        }
    }

    pub fn updateThread(a: *Agent) void {
        log.debug("Spawning update thread", .{});
        const alloc = std.heap.page_allocator;
        const names = allNames(alloc) catch unreachable;
        defer {
            for (names) |n| alloc.free(n);
            alloc.free(names);
        }

        sleep(1000_000_000 * 20);
        running: while (a.enabled) {
            log.info("Starting sync for {} repos", .{names.len});
            for (names) |rname| {
                log.debug("starting update for {s}", .{rname});
                var repo: Git.Repo = open(rname, .public) catch {
                    log.warn("unable to load public repo {s}", .{rname});
                    continue;
                } orelse open(rname, .private) catch {
                    log.warn("unable to load private repo {s}", .{rname});
                    continue;
                } orelse {
                    log.warn("unable to find repo {s}", .{rname});
                    continue;
                };
                defer repo.raze();

                repo.loadData(alloc) catch {
                    log.err("Warning, unable to load data for repo {s}", .{rname});
                    continue;
                };

                if (a.config.upstream.pull) {
                    pullUpstream(alloc, rname, &repo) catch |err| {
                        log.err("Error ({}) when trying to pull on {s}\n", .{ err, rname });
                        break :running;
                    };
                }
                if (a.config.downstream.push) {
                    pushDownstream(alloc, rname, &repo) catch |err| {
                        log.err("Error ({}) when trying to push on {s}\n", .{ err, rname });
                        break :running;
                    };
                }
            }
            log.debug("update cycle complete", .{});
            var qi: usize = 60 * 60;
            while (qi > 0) {
                qi -|= 1;
                sleep(a.config.sleep_for / 60 / 60);
                if (!a.enabled) break :running;
            }
        }
        log.info("Update thread complete!", .{});
    }
};

const std = @import("std");
const log = std.log.scoped(.update_thread);
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const sleep = std.Thread.sleep;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const indexOfPos = std.mem.indexOfPos;
const parseInt = std.fmt.parseInt;

const Git = @import("git.zig");
const SrcConfig = @import("main.zig").SrcConfig;
const global_config = &@import("main.zig").global_config.config;
