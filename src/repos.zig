const std = @import("std");

const Allocator = std.mem.Allocator;

const Git = @import("git.zig");
const Ini = @import("ini.zig");

const Repos = @This();

pub fn allNames(a: Allocator) ![][]u8 {
    var list = std.ArrayList([]u8).init(a);

    const cwd = std.fs.cwd();
    var repo_dirs = cwd.openIterableDir("repos", .{}) catch unreachable;
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
        var http = try std.mem.join(a, "", &joiner);
        return http;
    }

    return try a.dupe(u8, url);
}

pub fn hasUpstream(a: Allocator, r: Git.Repo) !?[]u8 {
    var conffd = try r.dir.openFile("config", .{});
    defer conffd.close();
    const conf = try Ini.init(a, conffd);
    defer conf.raze(a);
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
    const conf = try Ini.init(a, conffd);
    defer conf.raze(a);
    if (conf.get("remote \"downstream\"")) |ns| {
        if (ns.get("url")) |url| {
            return try a.dupe(u8, url);
        }
    }
    return null;
}

pub fn updateThread() void {
    std.debug.print("Spawning update thread\n", .{});
    const a = std.heap.page_allocator;
    const names = allNames(a) catch unreachable;
    defer {
        for (names) |n| a.free(n);
        a.free(names);
    }
    const sleep_for = 60 * 60 * 1000 * 1000 * 1000;
    var name_buffer: [2048]u8 = undefined;
    var update_buffer: [512]u8 = undefined;

    std.time.sleep(sleep_for);
    //std.time.sleep(1000 * 1000 * 1000);
    while (true) {
        for (names) |rname| {
            const dirname = std.fmt.bufPrint(&name_buffer, "repos/{s}", .{rname}) catch return;
            var dir = std.fs.cwd().openDir(dirname, .{}) catch continue;
            var repo = Git.Repo.init(dir) catch continue;
            defer repo.raze(a);
            repo.loadData(a) catch {
                std.debug.print("Warning, unable to load data for repo {s}\n", .{rname});
            };

            const rhead = repo.HEAD(a) catch continue;
            var head: []const u8 = switch (rhead) {
                .branch => |b| b.name[std.mem.lastIndexOf(u8, b.name, "/") orelse 0 ..][1..],
                .tag => |t| t.name,
                else => "main",
            };

            const update = std.fmt.bufPrint(
                &update_buffer,
                "update {}\n",
                .{std.time.timestamp()},
            ) catch unreachable;

            if (hasUpstream(a, repo) catch continue) |up| {
                repo.dir.writeFile("srctree_last_update", update) catch {};
                a.free(up);
                var acts = repo.getActions(a);
                const updated = acts.updateUpstream(head) catch er: {
                    std.debug.print("Warning, unable to update repo {s}\n", .{rname});
                    break :er false;
                };
                if (!updated) std.debug.print("Warning, update failed repo {s}\n", .{rname});
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
            if (repo_update > last_push) {
                if (hasDownstream(a, repo) catch continue) |down| {
                    repo.dir.writeFile("srctree_last_downdate", update) catch {};
                    a.free(down);
                    var acts = repo.getActions(a);
                    const updated = acts.updateDownstream() catch er: {
                        std.debug.print("Warning, unable to push to downstream repo {s}\n", .{rname});
                        break :er false;
                    };
                    if (!updated) std.debug.print("Warning, update failed repo {s}\n", .{rname});
                }
            } else {
                std.debug.print("Skipping for {s} no new branches {} {}\n", .{ rname, repo_update, last_push });
            }
        }
        std.time.sleep(sleep_for);
    }
}
