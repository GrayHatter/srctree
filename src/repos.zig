const std = @import("std");

const Allocator = std.mem.Allocator;

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
