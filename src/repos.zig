const std = @import("std");

const Allocator = std.mem.Allocator;

const Git = @import("git.zig");
const Ini = @import("ini.zig");

const Repos = @This();

const DEBUG = false;

pub fn allNames(a: Allocator) ![][]u8 {
    var list = std.ArrayList([]u8).init(a);

    const cwd = std.fs.cwd();
    var repo_dirs = cwd.openDir("repos", .{ .iterate = true }) catch unreachable;
    defer repo_dirs.close();
    var itr_repo = repo_dirs.iterate();

    while (itr_repo.next() catch null) |dir| {
        if (dir.kind != .directory and dir.kind != .sym_link) continue;
        try list.append(try a.dupe(u8, dir.name));
    }
    return try list.toOwnedSlice();
}

pub fn containsName(name: []const u8) bool {
    return if (name.len > 0) true else false;
}

pub fn parseGitRemoteUrl(a: Allocator, url: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, url, "https://")) return try a.dupe(u8, url);

    if (std.mem.startsWith(u8, url, "git@")) {
        const end = if (std.mem.endsWith(u8, url, ".git")) url.len - 4 else url.len;
        var p = try a.dupe(u8, url[4..end]);
        if (std.mem.indexOf(u8, p, ":")) |i| p[i] = '/';
        const joiner = [_][]const u8{ "https://", p };
        const http = try std.mem.join(a, "", &joiner);
        return http;
    }

    return try a.dupe(u8, url);
}

pub fn hasUpstream(a: Allocator, r: Git.Repo) !?[]u8 {
    var conffd = try r.dir.openFile("config", .{});
    defer conffd.close();
    const conf = try Ini.fromFile(a, conffd);
    defer conf.raze();
    if (conf.get("remote \"upstream\"")) |ns| {
        if (ns.get("url")) |url| {
            return try a.dupe(u8, url);
        }
    }
    return null;
}

pub fn hasDownstream(a: Allocator, r: Git.Repo) !?[]u8 {
    var conffd = try r.dir.openFile("config", .{});
    defer conffd.close();
    const conf = try Ini.fromFile(a, conffd);
    defer conf.raze();
    if (conf.get("remote \"downstream\"")) |ns| {
        if (ns.get("url")) |url| {
            return try a.dupe(u8, url);
        }
    }
    return null;
}

pub const AgentConfig = struct {
    running: bool = true,
    sleep_for: usize = 60 * 60 * 1000 * 1000 * 1000,
    g_config: *Ini.Config,
};

fn pushUpstream(a: Allocator, name: []const u8, repo: *Git.Repo) !void {
    var update_buffer: [512]u8 = undefined;
    const update = std.fmt.bufPrint(
        &update_buffer,
        "update {}\n",
        .{std.time.timestamp()},
    ) catch unreachable;

    const rhead = try repo.*.HEAD(a);
    const head: []const u8 = switch (rhead) {
        .branch => |b| b.name[std.mem.lastIndexOf(u8, b.name, "/") orelse 0 ..][1..],
        .tag => |t| t.name,
        else => "main",
    };
    if (try hasUpstream(a, repo.*)) |up| {
        repo.dir.writeFile(.{ .sub_path = "srctree_last_update", .data = update }) catch {};
        a.free(up);
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
    if (cfg.g_config.get("agent")) |agent| {
        if (agent.getBool("push_upstream") orelse false) {
            push_upstream = true;
        }
    }

    std.time.sleep(cfg.sleep_for);
    //std.time.sleep(1000 * 1000 * 1000);
    while (cfg.running) {
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
                if (hasDownstream(a, repo) catch continue) |down| {
                    repo.dir.writeFile(.{ .sub_path = "srctree_last_downdate", .data = update }) catch {};
                    a.free(down);
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
        std.time.sleep(cfg.sleep_for);
    }
}
