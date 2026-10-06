bytes: []u8 = &.{},
sha: Sha,
tree: Sha,
/// 9 ought to be enough for anyone... or at least robinli ... at least for a while
/// TODO fix and make this dynamic
parent: [9]?Sha = @splat(null),
author: Actor,
committer: Actor,

/// Raw message including the title and body
message: []const u8,
title: []const u8,
body: []const u8,
gpgsig: ?GPGSig,

ptr_parent: ?*Commit = null, // TOOO multiple parents

const Commit = @This();

pub fn init(sha: Sha, data: []const u8) !Commit {
    var r: Reader = .fixed(data);
    return init1(sha, &r);
}

pub fn init1(sha: Sha, r: *Reader) !Commit {
    var p_idx: usize = 0;
    var parent: [9]?Sha = @splat(null);
    var tree: ?Sha = null;
    var author: ?Actor = null;
    var committer: ?Actor = null;

    const width: usize = switch (sha.hash) {
        .sha1 => 40,
        .sha256 => 64,
        .partial => unreachable,
    };

    while (r.takeSentinel('\n')) |line| {
        if (line.len == 0) break;
        if (cutPrefix(u8, line, "gpgsig ")) |_| {
            gpgSig(r) catch |e| {
                log.err("GPG sig failed {}\n", .{e});
                log.debug("full stack '''\n{s}\n'''\n", .{r.buffered()});
                return e;
            };
            continue;
        }
        if (trim(u8, line, " \t").len != line.len) continue;
        if (cutPrefix(u8, line, "tree ")) |payload| {
            tree = .init(payload[0..width]);
        } else if (cutPrefix(u8, line, "parent ")) |payload| {
            if (p_idx >= parent.len) return error.TooManyParents;
            parent[p_idx] = .init(payload[0..width]);
            p_idx += 1;
        } else if (cutPrefix(u8, line, "author ")) |payload| {
            author = try Actor.make(payload);
        } else if (cutPrefix(u8, line, "committer ")) |payload| {
            committer = try Actor.make(payload);
        } else inline for (&.{ "change-id", "mergetag" }) |other_header| {
            if (cutPrefix(u8, line, other_header)) |_| {
                log.debug("unsupported git header: '{s}'\n\t\t'{any}'", .{ other_header, line });
                break;
            }
        } else {
            log.warn("unknown header: {any} '{s}'", .{ line, line });
            if (comptime debug_mode) return error.UnknownHeader;
        }
    } else |_| {}

    var message = r.buffered();
    var title: []const u8 = message;
    var body: []const u8 = "";
    if (find(u8, message, "\n\n")) |nl| {
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
        .title = title,
        .body = body,
        .gpgsig = null, // TODO still unimplemented
    };
}

pub fn initOwned(sha: Sha, data: []u8) !Commit {
    var commit = try init(sha, data);
    commit.bytes = data;
    return commit;
}

pub fn iterate(cmt: Commit, repo: *const Repo) Iterator {
    return .init(cmt, .linear, repo);
}

pub fn toParent(self: Commit, idx: u8, repo: *const Repo, a: Allocator, io: Io) !Commit {
    if (idx >= self.parent.len) return error.NoParent;
    if (self.parent[idx]) |parent| {
        return switch (try repo.objects.load(parent, a, io)) {
            .commit => |c| c,
            else => error.NotACommit,
        };
    }
    return error.NoParent;
}

pub fn loadTree(commit: Commit, repo: *const Repo, a: Allocator, io: Io) !Tree {
    return switch (try repo.objects.load(commit.tree, a, io)) {
        .tree => |t| t,
        else => error.NotATree,
    };
}

pub fn loadTreeDescend(commit: Commit, baseN: ?[]const u8, repo: *const Repo, a: Allocator, io: Io) !Tree {
    const base = baseN orelse return commit.loadTree(repo, a, io);
    switch (try repo.objects.load(commit.tree, a, io)) {
        .tree => |t| {
            if (t.descend(base, repo, a, io)) |des| {
                defer t.raze(a);
                return des;
            } else |err| switch (err) {
                error.CurrentTree => return t,
                else => return err,
            }
        },
        else => return error.NotATree,
    }
}

pub fn raze(self: Commit, a: Allocator) void {
    a.free(self.bytes);
}

pub fn format(cmt: Commit, out: *Writer) !void {
    try out.print("Commit{{\ncommit {s}\ntree {s}\n", .{ cmt.sha.slice(10), cmt.tree.slice(10) });
    for (cmt.parent) |par| {
        if (par == null) break;
        try out.print("parent {s}\n", .{par.?.slice(10)});
    }
    try out.print("author {f}\ncommiter {f}\n\n{s}\n}}", .{ cmt.author, cmt.committer, cmt.message });
}

/// TODO this
fn gpgSig(r: *Reader) !void {
    while (r.takeSentinel('\n')) |line| {
        if (find(u8, line, "-----END PGP SIGNATURE-----") != null) return;
        if (find(u8, line, "-----END SSH SIGNATURE-----") != null) return;
    } else |e| return e;
    return error.InvalidGpgsig;
}

pub const Iterator = struct {
    primary: Commit,
    branch: ?Commit = null,
    right: ?Commit = null,
    hold: ArrayList(Commit) = .empty,
    repo: *const Repo,
    strat: Strategy,
    now: Io.Timestamp = .zero,
    // expected/found common root commit
    common: ?Sha = null,

    pub const Strategy = enum {
        /// returns commits exclusively from the "main" branch, ignoring any commit that are
        /// normally reachable via merge commits
        main_branch,
        /// Expects "fast-forward" only, and returns `error.Branching` on merge commits.
        branch_error,
        /// returns commits from any branch, ignoring order
        linear,
        /// returns commits ordered by committer.timestamp, (BUG: ignoring timezone)
        /// descending branches as required to list all commits in the order they were
        /// committed to the branch.
        interleave,
        /// returns commits ordered by author.timestamp, (BUG: ignoring timezone) descending
        /// branches as required to list all commits in the order each commit
        chronological,
    };

    pub fn init(c: Commit, s: Strategy, repo: *const Repo) Iterator {
        return .{
            .primary = c,
            .strat = s,
            .repo = repo,
        };
    }

    pub fn raze(itr: *Iterator, a: Allocator) void {
        itr.hold.deinit(a);
    }

    pub fn next(itr: *Iterator, a: Allocator, io: Io) !?Commit {
        if (itr.primary.parent[0] == null) return null;

        return switch (itr.strat) {
            .main_branch => itr.nextMainOnly(a, io),
            .linear => itr.nextLinear(a, io),
            .interleave => itr.nextInterleave(a, io),
            .chronological => itr.nextMainOnly(a, io),
            .branch_error => itr.nextBranchError(a, io),
        };
    }

    pub fn nextMainOnly(itr: *Iterator, a: Allocator, io: Io) !?Commit {
        return itr.primary.toParent(0, itr.repo, a, io) catch |err| switch (err) {
            error.NoParent => unreachable,
            else => |e| return e,
        };
    }

    pub fn nextBranchError(itr: *Iterator, a: Allocator, io: Io) !?Commit {
        if (itr.primary.parent[1] != null) return error.Branching;
        return itr.primary.toParent(0, itr.repo, a, io) catch |err| switch (err) {
            error.NoParent => unreachable,
            else => |e| return e,
        };
    }

    pub fn nextLinear(itr: *Iterator, a: Allocator, io: Io) !?Commit {
        if (itr.common == null and itr.primary.parent[1] != null) {
            const left = try itr.primary.toParent(0, itr.repo, a, io);
            defer left.raze(a);
            const right = try itr.primary.toParent(1, itr.repo, a, io);
            itr.common = try itr.findCommon(&left, &right, a, io);
            if (itr.common != null) {
                itr.branch = right;
                return right;
            }
        }

        if (itr.branch) |branch| {
            if (branch.parent[1] != null) @panic("TODO");

            const branch_parent = try branch.toParent(0, itr.repo, a, io);
            if (!branch_parent.sha.eql(itr.common.?)) {
                itr.branch = branch_parent;
                return branch_parent;
            }
            branch_parent.raze(a);
            itr.common = null;
            itr.branch = null;
        }

        itr.primary = itr.primary.toParent(0, itr.repo, a, io) catch |err| switch (err) {
            error.NoParent => unreachable,
            else => |e| return e,
        };
        return itr.primary;
    }

    pub fn nextInterleave(_: *Iterator, _: Allocator, _: Io) !?Commit {
        unreachable;
    }

    pub fn nextChronological(_: *Iterator, _: Allocator, _: Io) !?Commit {
        unreachable;
    }

    fn findCommon(
        itr: *const Iterator,
        left: *const Commit,
        right: *const Commit,
        a: Allocator,
        io: Io,
    ) !?Sha {
        if (left.parent[1] != null or right.parent[1] != null) @panic("not implemented");
        var l_parent = try left.toParent(0, itr.repo, a, io);
        defer l_parent.raze(a);
        var r_parent = try right.toParent(0, itr.repo, a, io);
        defer r_parent.raze(a);
        while (true) {
            if (l_parent.committer.timestamp == r_parent.committer.timestamp) {
                if (l_parent.sha.eql(r_parent.sha)) {
                    log.debug("common for {f} and {f} is {f}", .{ left.sha.text(), right.sha.text(), l_parent.sha.text() });
                    return l_parent.sha;
                } else {
                    @panic("not implemented");
                }
            } else if (l_parent.committer.timestamp > r_parent.committer.timestamp) {
                const old = l_parent;
                defer old.raze(a);
                l_parent = try l_parent.toParent(0, itr.repo, a, io);
            } else if (l_parent.committer.timestamp < r_parent.committer.timestamp) {
                const old = r_parent;
                defer old.raze(a);
                r_parent = try r_parent.toParent(0, itr.repo, a, io);
            }
        }
        return null;
    }
};

test "parse commit" {
    const commit_data =
        \\tree 863dce25c7370ca052f0efddd1e3aa73569fb37b
        \\parent ac7bc0f8c6d88e2595d6147f79d88b91476acdde
        \\author Gregory Mullen <github@gr.ht> 1747760721 -0700
        \\committer Gregory Mullen <github@gr.ht> 1747760721 -0700
        \\
        \\clean up blame.zig
    ;

    const commit = try Commit.init(Sha.init("ac7bc0f8c6d88e2595d6147f79d88b91476acdde"), commit_data);
    const parents: [9]?Sha = .{ Sha.init("ac7bc0f8c6d88e2595d6147f79d88b91476acdde"), null, null, null, null, null, null, null, null };
    try std.testing.expectEqualSlices(?Sha, &parents, &commit.parent);
    try std.testing.expectEqual(Sha.init("863dce25c7370ca052f0efddd1e3aa73569fb37b"), commit.tree);
    try std.testing.expectEqualStrings("Gregory Mullen", commit.author.name);
    try std.testing.expectEqualStrings("github@gr.ht", commit.author.email);
    try std.testing.expectEqual(1747760721, commit.author.timestamp);
    try std.testing.expectEqualStrings("-0700", commit.author.tzstr);
    try std.testing.expectEqualStrings("Gregory Mullen", commit.committer.name);
    try std.testing.expectEqualStrings("github@gr.ht", commit.committer.email);
    try std.testing.expectEqual(1747760721, commit.committer.timestamp);
    try std.testing.expectEqualStrings("-0700", commit.committer.tzstr);
}

test "fuzz" {
    const Context = struct {
        fn testOne(context: @This(), smth: *std.testing.Smith) anyerror!void {
            _ = context;
            const input = smth.value([40]u8);
            if (input.len < 20) return;
            if (init(.init(input[0..20]), input[20..])) |_| {
                try std.testing.expect(false);
            } else |_| {
                return;
            }
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}

test Iterator {
    const a = std.testing.allocator;
    const io = std.testing.io;

    //const cwd = try Io.Dir.cwd().openDir(io, "../gr.ht.hugo", .{});
    const cwd = try Io.Dir.cwd().openDir(io, ".", .{});
    var repo = try Repo.init(cwd, io);
    try repo.loadData(a, io);
    defer repo.raze(a, io);

    const cmtt = try repo.HEAD(a, io);
    defer cmtt.raze(a);

    var itr = cmtt.iterate(&repo);

    var remain: usize = 50;
    while (try itr.next(a, io)) |next| {
        defer next.raze(a);
        log.debug("found {f}", .{next.sha.text()});
        if (remain == 0) break;
        remain -= 1;
    }
}

test {
    _ = &std.testing.refAllDecls(@This());
}

const debug_mode: bool = @import("builtin").mode == .debug;

const Sha = @import("Sha.zig");
const Repo = @import("Repo.zig");
const Tree = @import("Tree.zig");
const Actor = @import("Actor.zig");
const Objects = @import("Objects.zig");

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const Reader = Io.Reader;
const log = std.log.scoped(.git_commit);
const eql = std.mem.eql;
const find = std.mem.find;
const findScalar = std.mem.findScalar;
const startsWith = std.mem.startsWith;
const cutPrefix = std.mem.cutPrefix;
const trim = std.mem.trim;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

// TODO not currently implemented
pub const GPGSig = struct {};
