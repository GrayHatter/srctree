alloc: ?Allocator = null,
memory: ?[]const u8 = null,
sha: SHA,
tree: SHA,
/// 9 ought to be enough for anyone... or at least robinli ... at least for a while
/// TODO fix and make this dynamic
parent: [9]?SHA = .{null} ** 9,
author: Actor,
committer: Actor,
/// Raw message including the title and body
message: []const u8,
title: []const u8,
body: []const u8,
gpgsig: ?GPGSig,

ptr_parent: ?*Commit = null, // TOOO multiple parents

pub const Commit = @This();

pub fn init(sha: SHA, data: []const u8) !Commit {
    if (std.mem.startsWith(u8, data, "commit")) unreachable;
    var lines = std.mem.splitSequence(u8, data, "\n");
    // I don't like it either, but... lazy
    var p_idx: usize = 0;
    var parent: [9]?SHA = .{ null, null, null, null, null, null, null, null, null };
    var tree: ?SHA = null;
    var author: ?Actor = null;
    var committer: ?Actor = null;

    while (lines.next()) |line| {
        if (startsWith(u8, line, "gpgsig")) {
            gpgSig(&lines) catch |e| {
                std.debug.print("GPG sig failed {}\n", .{e});
                std.debug.print("full stack '''\n{s}\n'''\n", .{data});
                return e;
            };
            continue;
        }
        if (line.len == 0) break;
        // Seen in GPG headers set by github... thanks github :<
        if (trim(u8, line, " \t").len != line.len) continue;
        if (indexOf(u8, line, " ")) |brk| {
            const name = line[0..brk];
            const payload = line[brk + 1 ..];
            if (eql(u8, name, "tree")) {
                tree = SHA.init(payload[0..40]);
            } else if (eql(u8, name, "parent")) {
                if (p_idx >= parent.len) return error.TooManyParents;
                parent[p_idx] = SHA.init(payload[0..40]);
                p_idx += 1;
            } else if (eql(u8, name, "author")) {
                author = try Actor.make(payload);
            } else if (eql(u8, name, "committer")) {
                committer = try Actor.make(payload);
            } else {
                std.debug.print("unknown header: {any}\n", .{name});
                return error.UnknownHeader;
            }
        } else return error.MalformedHeader;
    }
    var message = lines.rest();
    var title: ?[]const u8 = null;
    var body: ?[]const u8 = null;
    if (indexOf(u8, message, "\n\n")) |nl| {
        title = message[0..nl];
        body = message[nl + 2 ..];
    }
    return .{
        .sha = sha,
        .tree = tree orelse return error.TreeMissing,
        .parent = parent,
        .author = author orelse return error.AuthorMissing,
        .committer = committer orelse return error.CommitterMissing,
        .message = message,
        .title = title orelse message,
        .body = body orelse "",
        .gpgsig = null, // TODO still unimplemented
    };
}

pub fn initOwned(sha: SHA, a: Allocator, object: Object) !Commit {
    var commit = try init(sha, object.body);
    commit.alloc = a;
    commit.memory = object.memory;
    return commit;
}

pub fn toParent(self: Commit, a: Allocator, idx: u8, repo: *const Repo) !Commit {
    if (idx >= self.parent.len) return error.NoParent;
    if (self.parent[idx]) |parent| {
        const tmp = try repo.loadObject(a, parent);
        return try initOwned(parent, a, tmp);
    }
    return error.NoParent;
}

pub fn mkTree(self: Commit, a: Allocator, repo: *const Repo) !Tree {
    const tmp = try repo.loadObject(a, self.tree);
    return try Tree.initOwned(self.tree, a, tmp);
}

pub fn mkSubTree(self: Commit, a: Allocator, subpath: ?[]const u8, repo: *const Repo) !Tree {
    const rootpath = subpath orelse return self.mkTree(a, repo);
    if (rootpath.len == 0) return self.mkTree(a, repo);

    var itr = std.mem.splitScalar(u8, rootpath, '/');
    var root = try self.mkTree(a, repo);
    root.path = try a.dupe(u8, rootpath);
    iter: while (itr.next()) |path| {
        for (root.blobs) |obj| {
            if (std.mem.eql(u8, obj.name, path)) {
                if (itr.rest().len == 0) {
                    defer root.raze();
                    var out = try obj.toTree(a, repo);
                    out.path = try a.dupe(u8, rootpath);
                    return out;
                } else {
                    const tree = try obj.toTree(a, repo);
                    defer root = tree;
                    root.raze();
                    continue :iter;
                }
            }
        } else return error.PathNotFound;
    }
    return root;
}

/// Warning; this function is probably unsafe
pub fn raze(self: Commit) void {
    if (self.alloc) |a| a.free(self.memory.?);
}

pub fn format(
    self: Commit,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    out: anytype,
) !void {
    try out.print(
        \\Commit{{
        \\commit {s}
        \\tree {s}
        \\
    , .{ self.sha.hex[0..], self.tree.hex[0..] });
    for (self.parent) |par| {
        if (par) |p|
            try out.print("parent {s}\n", .{p.hex[0..]});
    }
    try out.print(
        \\author {}
        \\commiter {}
        \\
        \\{s}
        \\}}
    , .{ self.author, self.committer, self.message });
}

/// TODO this
fn gpgSig(itr: *std.mem.SplitIterator(u8, .sequence)) !void {
    while (itr.next()) |line| {
        if (std.mem.indexOf(u8, line, "-----END PGP SIGNATURE-----") != null) return;
        if (std.mem.indexOf(u8, line, "-----END SSH SIGNATURE-----") != null) return;
    }
    return error.InvalidGpgsig;
}

const SHA = @import("SHA.zig");
const Repo = @import("Repo.zig");
const Tree = @import("tree.zig");
const Actor = @import("actor.zig");
const Object = @import("Object.zig");

const std = @import("std");
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const startsWith = std.mem.startsWith;
const trim = std.mem.trim;
const Allocator = std.mem.Allocator;
const AnyReader = std.io.AnyReader;

// TODO not currently implemented
pub const GPGSig = struct {};
