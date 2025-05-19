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
    var list = std.ArrayList([]u8).init(a);

    var dir_set = try dirs.directory(.public);
    defer dir_set.close();
    var itr_repo = dir_set.iterate();

    while (itr_repo.next() catch null) |dir| {
        if (dir.kind != .directory and dir.kind != .sym_link) continue;
        if (isHidden(dir.name)) continue;
        try list.append(try a.dupe(u8, dir.name));
    }
    return try list.toOwnedSlice();
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

pub const AgentConfig = struct {
    const SECONDS = 1000 * 1000 * 1000;
    running: bool = true,
    sleep_for: usize = 60 * 60 * SECONDS,
    agent: *const ?SrcConfig.Base.Agent,
};

fn pushUpstream(a: Allocator, name: []const u8, repo: *Git.Repo) !void {
    var update_buffer: [512]u8 = undefined;
    const update = std.fmt.bufPrint(
        &update_buffer,
        "update {}\n",
        .{std.time.timestamp()},
    ) catch unreachable;

    const rhead = try repo.HEAD(a);
    const head: []const u8 = switch (rhead) {
        .branch => |b| b.name[std.mem.lastIndexOf(u8, b.name, "/") orelse 0 ..][1..],
        .tag => |t| t.name,
        else => "main",
    };

    if (try repo.findRemote("upstream")) |_| {
        repo.dir.writeFile(.{ .sub_path = "srctree_last_update", .data = update }) catch {};
        var agent = repo.getAgent(a);
        const updated = agent.updateUpstream(head) catch er: {
            std.debug.print("Warning, unable to update repo {s}\n", .{name});
            break :er false;
        };
        if (!updated) std.debug.print("Warning, update failed repo {s}\n", .{name});
    }
}

pub fn updateThread(cfg: *AgentConfig) void {
    std.debug.print("Spawning update thread\n", .{});
    const a = std.heap.page_allocator;
    const names = allNames(a) catch unreachable;
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    var name_buffer: [2048]u8 = undefined;

    var push_upstream: bool = false;
    if (cfg.agent.*) |agent| {
        if (agent.push_upstream) {
            push_upstream = true;
        }
    }

    sleep(cfg.sleep_for / 60 / 6);
    while (cfg.running) running: {
        for (names) |rname| {
            const dirname = std.fmt.bufPrint(&name_buffer, "repos/{s}", .{rname}) catch return;
            const dir = std.fs.cwd().openDir(dirname, .{}) catch continue;
            var repo = Git.Repo.init(dir) catch continue;
            defer repo.raze();
            repo.loadData(a) catch {
                std.debug.print("Warning, unable to load data for repo {s}\n", .{rname});
            };

            if (push_upstream) {
                pushUpstream(a, rname, &repo) catch {
                    std.debug.print("Error when trying to push on {s}\n", .{rname});
                    break;
                };
            }

            var rbuf: [0xff]u8 = undefined;
            const last_push_str = repo.dir.readFile("srctree_last_downdate", &rbuf) catch |err| switch (err) {
                error.FileNotFound => for (rbuf[0..9], "update 0\n") |*dst, src| {
                    dst.* = src;
                } else rbuf[0..9],
                else => {
                    std.debug.print("unable to read downstream update {}  '{s}'\n", .{ err, rname });
                    continue;
                },
            };
            const last_push = std.fmt.parseInt(i64, last_push_str[7 .. last_push_str.len - 1], 10) catch |err| {
                std.debug.print("unable to parse int {} '{s}'\n", .{ err, last_push_str });
                continue;
            };
            const repo_update = repo.updatedAt(a) catch 0;

            var update_buffer: [512]u8 = undefined;
            const update = std.fmt.bufPrint(
                &update_buffer,
                "update {}\n",
                .{std.time.timestamp()},
            ) catch unreachable;

            if (repo_update > last_push) {
                if (repo.findRemote("downstream") catch continue) |_| {
                    repo.dir.writeFile(.{ .sub_path = "srctree_last_downdate", .data = update }) catch {};
                    var agent = repo.getAgent(a);
                    const updated = agent.updateDownstream() catch er: {
                        std.debug.print("Warning, unable to push to downstream repo {s}\n", .{rname});
                        break :er false;
                    };
                    if (!updated) std.debug.print("Warning, update failed repo {s}\n", .{rname});
                }
            } else {
                if (DEBUG) {
                    std.debug.print("Skipping for {s} no new branches {} {}\n", .{ rname, repo_update, last_push });
                }
            }
        }

        var qi: usize = 60 * 60;
        while (qi > 0) {
            qi -|= 1;
            sleep(cfg.sleep_for / 60 / 60);
            if (!cfg.running) break :running;
        }
    }
    std.debug.print("update thread done!\n", .{});
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const sleep = std.time.sleep;
const eql = std.mem.eql;

const Git = @import("git.zig");
const SrcConfig = @import("main.zig").SrcConfig;
const global_config = &@import("main.zig").global_config.config;
