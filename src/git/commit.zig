const std = @import("std");
const Allocator = std.mem.Allocator;

const Git = @import("../git.zig");
const SHA = Git.SHA;
const Repo = Git.Repo;
const Tree = Git.Tree;
const Actor = @import("actor.zig");

pub const Commit = @This();

// TODO not currently implemented
pub const GPGSig = struct {};

alloc: ?Allocator = null,
blob: []const u8,
sha: SHA,
tree: SHA,
/// 9 ought to be enough for anyone... or at least robinli ... at least for a while
/// TODO fix and make this dynamic
parent: [9]?SHA,
author: Actor,
committer: Actor,
/// Raw message including the title and body
message: []const u8,
title: []const u8,
body: []const u8,
repo: ?*const Repo = null,
gpgsig: ?GPGSig,

ptr_parent: ?*Commit = null, // TOOO multiple parents

fn header(self: *Commit, data: []const u8) !void {
    if (std.mem.indexOf(u8, data, " ")) |brk| {
        const name = data[0..brk];
        const payload = data[brk..];
        if (std.mem.eql(u8, name, "commit")) {
            if (std.mem.indexOf(u8, data, "\x00")) |nl| {
                self.tree = payload[nl..][0..40];
            } else unreachable;
        } else if (std.mem.eql(u8, name, "tree")) {
            self.tree = payload[1..41];
        } else if (std.mem.eql(u8, name, "parent")) {
            for (&self.parent) |*parr| {
                if (parr.* == null) {
                    parr.* = payload[1..41];
                    return;
                }
            }
        } else if (std.mem.eql(u8, name, "author")) {
            self.author = try Actor.make(payload);
        } else if (std.mem.eql(u8, name, "committer")) {
            self.committer = try Actor.make(payload);
        } else {
            std.debug.print("unknown header: {s}\n", .{name});
            return error.UnknownHeader;
        }
    } else return error.MalformedHeader;
}

/// TODO this
fn gpgSig(_: *Commit, itr: *std.mem.SplitIterator(u8, .sequence)) !void {
    while (itr.next()) |line| {
        if (std.mem.indexOf(u8, line, "-----END PGP SIGNATURE-----") != null) return;
        if (std.mem.indexOf(u8, line, "-----END SSH SIGNATURE-----") != null) return;
    }
    return error.InvalidGpgsig;
}

pub fn initAlloc(a: Allocator, sha_in: SHA, data: []const u8) !Commit {
    const sha = try a.dupe(u8, sha_in);
    const blob = try a.dupe(u8, data);

    var self = try make(sha, blob, a);
    self.alloc = a;
    return self;
}

pub fn init(sha: SHA, data: []const u8) !Commit {
    return make(sha, data, null);
}

pub fn make(sha: SHA, data: []const u8, a: ?Allocator) !Commit {
    _ = a;
    var lines = std.mem.split(u8, data, "\n");
    var self: Commit = undefined;
    self.repo = null;
    // I don't like it either, but... lazy
    self.parent = .{ null, null, null, null, null, null, null, null, null };
    self.blob = data;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "gpgsig")) {
            self.gpgSig(&lines) catch |e| {
                std.debug.print("GPG sig failed {}\n", .{e});
                std.debug.print("full stack '''\n{s}\n'''\n", .{data});
                return e;
            };
            continue;
        }
        if (line.len == 0) break;
        // Seen in GPG headers set by github... thanks github :<
        if (std.mem.trim(u8, line, " \t").len != line.len) continue;

        self.header(line) catch |e| {
            std.debug.print("header failed {} on {} '{s}'\n", .{ e, lines.index.?, line });
            std.debug.print("full stack '''\n{s}\n'''\n", .{data});
            return e;
        };
    }
    self.message = lines.rest();
    if (std.mem.indexOf(u8, self.message, "\n\n")) |nl| {
        self.title = self.message[0..nl];
        self.body = self.message[nl + 2 ..];
    } else {
        self.title = self.message;
        self.body = self.message[0..0];
    }
    self.sha = sha;
    return self;
}

pub fn fromReader(a: Allocator, sha: SHA, reader: Git.Reader) !Commit {
    var buffer: [0xFFFF]u8 = undefined;
    const len = try reader.readAll(&buffer);
    return try initAlloc(a, sha, buffer[0..len]);
}

pub fn toParent(self: Commit, a: Allocator, idx: u8) !Commit {
    if (idx >= self.parent.len) return error.NoParent;
    if (self.parent[idx]) |parent| {
        if (self.repo) |repo| {
            var obj = try repo.findObj(a, parent);
            defer obj.raze(a);
            var cmt = try Commit.fromReader(a, parent, obj.reader());
            cmt.repo = repo;
            return cmt;
        }
        return error.DetachedCommit;
    }
    return error.NoParent;
}

pub fn mkTree(self: Commit, a: Allocator) !Tree {
    if (self.repo) |repo| {
        return try Tree.fromRepo(a, repo.*, self.tree);
    } else return error.DetachedCommit;
}

pub fn mkSubTree(self: Commit, a: Allocator, subpath: ?[]const u8) !Tree {
    const path = subpath orelse return self.mkTree(a);
    if (path.len == 0) return self.mkTree(a);

    var itr = std.mem.split(u8, path, "/");
    var root = try self.mkTree(a);
    root.path = try a.dupe(u8, path);
    iter: while (itr.next()) |p| {
        for (root.objects) |obj| {
            if (std.mem.eql(u8, obj.name, p)) {
                if (itr.rest().len == 0) {
                    defer root.raze(a);
                    var out = try obj.toTree(a, self.repo.?.*);
                    out.path = try a.dupe(u8, path);
                    return out;
                } else {
                    const tree = try obj.toTree(a, self.repo.?.*);
                    defer root = tree;
                    root.raze(a);
                    continue :iter;
                }
            }
        } else return error.PathNotFound;
    }
    return root;
}

/// Warning; this function is probably unsafe
pub fn raze(self: Commit) void {
    if (self.alloc) |a| {
        a.free(self.sha);
        a.free(self.blob);
    }
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
    , .{ self.sha, self.tree });
    for (self.parent) |par| {
        if (par) |p|
            try out.print("parent {s}\n", .{p});
    }
    try out.print(
        \\author {}
        \\commiter {}
        \\
        \\{s}
        \\}}
    , .{ self.author, self.committer, self.message });
}
