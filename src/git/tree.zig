sha: Sha,
bytes: []const u8,
name: ?[]const u8 = null,
parent: ?*const Tree = null,
basepath: ?[]const u8 = null,

const Tree = @This();

pub const Path2 = struct {
    pub fn init(sha: Sha, blob: []const u8, parent: Sha, path: []const u8, a: Allocator) !Path2 {
        return .{
            .tree = .init(sha, a, blob),
            .parent = parent,
            .name = try a.dupe(u8, path),
        };
    }

    pub fn descend(tree: *const Path2, path: []const u8, repo: *const Repo, a: Allocator, io: Io) DescendError!Path2 {
        std.debug.assert(path.len > 0);

        var path_itr = componentIterator(path);
        var root: Path2 = if (repo.objects.load(tree.tree.sha, a, io)) |rt| switch (rt) {
            .tree => |t| t.withPath(path),
            else => return error.InvalidTreeSha,
        } else |_| unreachable;

        iter: while (path_itr.next()) |path_next| {
            var itr = root.iterate();
            while (itr.next()) |obj| {
                if (eql(u8, obj.name, path_next.name)) {
                    if (path_itr.peekNext() != null) {
                        defer root.raze(a);
                        return (obj.toTree(repo, a, io) catch @panic("FIXME")).withPath(path_next.path);
                    }
                    root.raze(a);
                    root = (obj.toTree(repo, a, io) catch @panic("FIXME")).withPath(path_next.path);
                    continue :iter;
                }
            } else return error.PathNotFound;
        }
        return root;
    }
};

pub fn init(sha: Sha, blob: []const u8) !Tree {
    return .{ .sha = sha, .bytes = blob };
}

pub fn loadSha(sha: Sha, repo: *const Repo, a: Allocator, io: Io) !Tree {
    const new = try repo.objects.load(sha, a, io);
    if (new != .tree) {
        std.log.err("sha {f}", .{sha.text()});
        unreachable;
    }
    return new.tree;
}

pub fn initAlloc(sha: Sha, body: []const u8, a: Allocator) !Tree {
    const blob = try a.dupe(u8, body);
    return .{ .sha = sha, .bytes = blob };
}

pub const DescendError = error{
    CurrentTree,
    InvalidPath,
    InvalidTreeSha,
    NotATree,
    OutOfMemory,
    PathNotFound,
};

// TODO leaks
pub fn descend(from: *const Tree, path: []const u8, repo: *const Repo, a: Allocator, io: Io) DescendError!Tree {
    var path_itr = componentIterator(path);
    const first = path_itr.first() orelse return error.CurrentTree;

    var itr = from.iterate();
    while (itr.next()) |next| {
        if (!eql(u8, next.name, first.name)) continue;

        if (repo.objects.load(next.sha, a, io)) |new| switch (new) {
            .tree => |new_tree| {
                errdefer new_tree.raze(a);

                if (path_itr.next()) |_| {
                    defer a.free(new_tree.bytes);
                    const tree: Tree = .{
                        .bytes = new.tree.bytes,
                        .sha = new.tree.sha,
                        .parent = from,
                        .name = next.name,
                    };
                    return try tree.descend(path_itr.path[path_itr.start_index..], repo, a, io);
                }

                return .{
                    .bytes = new.tree.bytes,
                    .sha = new.tree.sha,
                    .parent = from,
                    .name = next.name,
                };
            },
            inline else => |e| e.raze(a),
        } else |_| return error.InvalidTreeSha;
    }
    return error.PathNotFound;
}

// TODO leaks
pub fn descendBlob(from: *const Tree, path: []const u8, repo: *const Repo, a: Allocator, io: Io) DescendError!Blob {
    var path_itr = componentIterator(path);
    const first = path_itr.first() orelse return error.InvalidPath;

    var itr = from.iterate();
    while (itr.next()) |next| {
        if (!eql(u8, next.name, first.name)) continue;

        if (repo.objects.load(next.sha, a, io)) |new| switch (new) {
            .tree => |new_tree| {
                errdefer new_tree.raze(a);

                if (path_itr.next()) |_| {
                    defer a.free(new_tree.bytes);
                    const tree = try a.create(Tree);
                    errdefer a.destroy(tree);
                    tree.* = .{
                        .bytes = new.tree.bytes,
                        .sha = new.tree.sha,
                        .parent = from,
                        .name = next.name,
                    };
                    return try tree.descendBlob(path_itr.path[path_itr.start_index..], repo, a, io);
                }
            },
            .blob => |temp| {
                var bl = temp;
                bl.name = path_itr.path[path_itr.start_index..];
                return bl;
            },
            inline else => |e| e.raze(a),
        } else |_| return error.InvalidTreeSha;
    }
    return error.PathNotFound;
}

pub fn count(tree: Tree) usize {
    const width = tree.sha.size();
    const blob = tree.bytes;
    var i: usize = 0;
    if (find(u8, blob, "tree ")) |tidx| {
        if (findScalarPos(u8, blob, i, 0)) |index| {
            // This is probably wrong for large trees, but #YOLO
            std.debug.assert(tidx == 0);
            std.debug.assert(eql(u8, "tree ", blob[0..5]));
            i = index + 1;
        }
    }
    var real_count: usize = 0;
    while (findScalarPos(u8, blob, i, 0)) |str_end| {
        var mode: [6]u8 = @splat('0');
        var name = blob[i + 7 .. str_end];
        if (blob[i] == '1') {
            @memcpy(mode[0..6], blob[i..][0..6]);
        } else if (blob[i] == '4') {
            @memcpy(mode[1..6], blob[i..][0..5]);
            name = blob[i + 6 .. str_end];
        }
        real_count += 1;
        i = str_end + width + 1;
    }

    return real_count;
}

pub const Iterator = struct {
    tree: *const Tree,
    idx: usize = 0,

    pub fn next(itr: *Iterator) ?Blob {
        const width = itr.tree.sha.size();
        const blob = itr.tree.bytes;
        if (itr.idx >= blob.len) return null;
        while (findScalarPos(u8, blob, itr.idx, 0)) |str_end| {
            var mode: [6]u8 = @splat('0');
            var name = blob[itr.idx + 7 .. str_end];
            if (blob[itr.idx] == '1') {
                @memcpy(mode[0..6], blob[itr.idx..][0..6]);
            } else if (blob[itr.idx] == '4') {
                @memcpy(mode[1..6], blob[itr.idx..][0..5]);
                name = blob[itr.idx + 6 .. str_end];
            }
            defer itr.idx = str_end + width + 1;
            //std.debug.print(
            //    "next {any} {s} {s} {} \n",
            //    .{ mode, name, Sha.init(blob[str_end + 1 ..][0..width]).text().slice(), itr.idx },
            //);
            return .{
                .mode = mode,
                .name = name,
                .sha = .init(blob[str_end + 1 ..][0..width]),
                .bytes = &.{},
            };
        }
        return null;
    }

    pub fn peek(itr: *Iterator) ?Blob {
        const idx = itr.idx;
        defer itr.idx = idx;
        return itr.peek();
    }

    pub fn toSlice(itr: *Iterator, a: Allocator) ![]Blob {
        var list: ArrayList(Blob) = .empty;
        while (itr.next()) |nxt| try list.append(a, nxt);
        return try list.toOwnedSlice(a);
    }
};

pub fn iterate(tree: *const Tree) Iterator {
    if (startsWith(u8, tree.bytes, "tree "))
        if (findScalarPos(u8, tree.bytes, 0, 0)) |index|
            return .{ .tree = tree, .idx = index + 1 };
    return .{ .tree = tree, .idx = 0 };
}

pub fn changedSet(self: Tree, repo: *const Repo, a: Allocator, io: Io) ![]ChangeSet {
    const head = try repo.HEAD(a, io);
    defer head.raze(a);
    return self.changedSetFrom(repo, &head, a, io);
}

pub fn changedSetFrom(self: *const Tree, repo: *const Repo, root_commit: *const Commit, a: Allocator, io: Io) ![]ChangeSet {
    const search_list: []?Blob = try a.alloc(?Blob, self.count());
    defer a.free(search_list);
    var changed = try a.alloc(ChangeSet, self.count());
    errdefer a.free(changed);
    errdefer for (changed) |ch| ch.raze(a);

    var itr = self.iterate();
    for (search_list, changed) |*srch, *chng| {
        srch.* = itr.next() orelse unreachable;
        chng.* = .{ .sha = .empty, .name = &.{}, .title = &.{}, .timestamp = 0 };
    }

    var parent: Commit = root_commit.*;
    parent.bytes = try a.dupe(u8, parent.bytes);
    defer parent.raze(a);
    var tree = try root_commit.loadTree(repo, a, io);
    defer tree.raze(a);

    var found: usize = 0;
    while (found < search_list.len) {
        if (parent.toParent(0, repo, a, io)) |p| {
            parent.raze(a);
            parent = p;
        } else |err| switch (err) {
            error.NoParent, error.ObjectInvalid => {
                for (search_list, 0..) |search_ish, i| {
                    if (search_ish) |search| {
                        found += 1;
                        changed[i] = try .init(a, search.name, &parent);
                    }
                }
                break;
            },
            else => |e| return e,
        }

        if (parent.loadTree(repo, a, io)) |t| {
            tree.raze(a);
            tree = t;
        } else |err| switch (err) {
            error.ObjectInvalid => {
                for (search_list, 0..) |search_ish, i| {
                    if (search_ish) |search| {
                        found += 1;
                        changed[i] = try .init(a, search.name, &parent);
                    }
                }
                break;
            },
            else => |e| return e,
        }
        for (search_list, 0..) |*search_ish, i| {
            const search = search_ish.* orelse continue;
            const sha_bin: []const u8 = switch (search.sha.hash) {
                .sha1 => |sh| &sh,
                .sha256 => |sh| &sh,
                .partial => unreachable,
            };
            if (find(u8, tree.bytes, sha_bin) == null) {
                search_ish.* = null;
                found += 1;
                changed[i] = try .init(a, search.name, &parent);
                continue;
            }
        }
    }

    return changed;
}

pub fn raze(tree: Tree, a: Allocator) void {
    a.free(tree.bytes);
}

pub fn format(self: Tree, out: *Io.Writer) !void {
    var f: usize = 0;
    var d: usize = 0;
    var itr = self.iterate();

    while (itr.next()) |obj| {
        if (obj.mode[0] == 48)
            d += 1
        else
            f += 1;
    }
    try out.print("Tree{{ {} Objects, {} files {} directories }}", .{ self.count(), f, d });
}

test "traverse" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const cwd = Io.Dir.cwd().openDir(io, "repos/hastur", .{}) catch return error.SkipZigTest;
    var repo = try Repo.init(cwd, io);
    try repo.loadData(a, io);
    defer repo.raze(a, io);
}

test "tree decom" {
    var a = std.testing.allocator;
    const io = std.testing.io;
    var cwd = Io.Dir.cwd();

    var file = cwd.openFile(io, "./.git/objects/5e/dabf724389ef87fa5a5ddb2ebe6dbd888885ae", .{}) catch |err|
        switch (err) {
            error.FileNotFound => {
                return error.SkipZigTest;
                // Sadly this was a predictable error that past me should have know
                // better, alas, actually fixing it [by creating a test vector repo]
                // is still a future me problem!
            },
            else => return err,
        };

    var r_b: [2048]u8 = undefined;
    var reader = file.reader(io, &r_b);
    var z_b: [2048]u8 = undefined;
    var d = zstd.Decompress.init(&reader.interface, &z_b, .{});
    try d.reader.fillMore();
    const b = d.reader.buffered();
    const buf = try a.dupe(u8, b[0..]);
    defer a.free(buf);
    const blob = buf[(find(u8, buf, "\x00") orelse unreachable) + 1 ..];
    const tree = try Tree.init(Sha.init("5edabf724389ef87fa5a5ddb2ebe6dbd888885ae"), blob);
    defer tree.raze(a);
    var itr = tree.iterate();
    while (itr.next()) |tobj| {
        if (false) std.debug.print("{s} {s} {s}\n", .{ tobj.mode, tobj.hash, tobj.name });
    }
    if (false) std.debug.print("{}\n", .{tree});
}

test "mk sub tree" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const cwd = try Io.Dir.cwd().openDir(io, ".", .{});
    var repo = try Repo.init(cwd, io);
    defer repo.raze(a, io);

    try repo.loadData(a, io);

    const cmtt = try repo.HEAD(a, io);
    defer cmtt.raze(a);

    var tree = try cmtt.loadTree(&repo, a, io);
    defer tree.raze(a);

    var itr = tree.iterate();
    var blob: Blob = blb: while (itr.next()) |obj| {
        if (eql(u8, obj.name, "src")) break :blb obj;
    } else return error.ExpectedBlobMissing;
    var subtree = try blob.toTree(&repo, a, io);
    if (false) std.debug.print("{any}\n", .{subtree});
    var subitr = subtree.iterate();
    while (subitr.next()) |obj| {
        std.log.debug("{any}", .{obj});
    }

    subtree.raze(a);
}

test "commit mk sub tree" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const cwd = try Io.Dir.cwd().openDir(io, ".", .{});
    var repo = try Repo.init(cwd, io);
    defer repo.raze(a, io);

    try repo.loadData(a, io);

    const cmtt = try repo.HEAD(a, io);
    defer cmtt.raze(a);

    var tree = try cmtt.loadTree(&repo, a, io);
    defer tree.raze(a);

    var itr = tree.iterate();
    var blob: Blob = blb: while (itr.next()) |obj| {
        if (eql(u8, obj.name, "src")) break :blb obj;
    } else return error.ExpectedBlobMissing;
    var subtree = try blob.toTree(&repo, a, io);
    if (false) std.debug.print("{any}\n", .{subtree});

    var subitr = tree.iterate();
    while (subitr.next()) |obj| {
        if (false) std.debug.print("{any}\n", .{obj});
    }
    defer subtree.raze(a);

    {
        const csubtree = try cmtt.loadTree(&repo, a, io);
        defer csubtree.raze(a);
        const subdsnd = try csubtree.descend("src", &repo, a, io);
        defer subdsnd.raze(a);
        std.log.debug("{any}\n", .{csubtree});
    }

    {
        const csubtree2 = try cmtt.loadTree(&repo, a, io);
        defer csubtree2.raze(a);
        const subdsnd2 = try csubtree2.descend("src/endpoints", &repo, a, io);
        defer subdsnd2.raze(a);
        std.log.debug("{any}\n", .{subdsnd2});
        var sub2_itr = subdsnd2.iterate();
        while (sub2_itr.next()) |obj|
            std.log.debug("sub2itr {s} {any}\n", .{ obj.name, obj });
        const changed = try subdsnd2.changedSet(&repo, a, io);
        var subitr2 = subdsnd2.iterate();
        var c_idx: usize = 0;
        while (true) {
            const o = subitr2.next() orelse break;
            const c = changed[c_idx];
            c_idx += 1;

            if (false) std.debug.print("{s} {s}\n", .{ o.name, c.sha });
            c.raze(a);
        }
        a.free(changed);
    }
}

const Sha = @import("Sha.zig");
const Repo = @import("Repo.zig");
const Blob = @import("blob.zig");
const Commit = @import("Commit.zig");
const ChangeSet = @import("changeset.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const bufPrint = std.fmt.bufPrint;
const zstd = std.compress.zstd;
const find = std.mem.find;
const findScalarPos = std.mem.findScalarPos;
const join = std.mem.join;
const countScalar = std.mem.countScalar;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const assert = std.debug.assert;
const componentIterator = std.fs.path.componentIterator;
