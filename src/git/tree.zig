sha: Sha,
bytes: []const u8,

const Tree = @This();

pub const Path = struct {
    tree: Tree,
    parent: ?Sha = null,
    path: []const u8,

    pub const DescendError = error{
        InvalidSha,
        OutOfMemory,
        PathNotFound,
    };

    pub fn init(sha: Sha, blob: []const u8, parent: Sha, path: []const u8, a: Allocator) !Path {
        return .{
            .tree = .init(sha, a, blob),
            .parent = parent,
            .paths = try a.dupe(u8, path),
        };
    }

    pub fn descend(tree: *const Path, path: []const u8, repo: *const Repo, a: Allocator, io: Io) DescendError!Path {
        std.debug.assert(path.len > 0);

        var path_itr = std.fs.path.componentIterator(path);
        var root: Path = if (repo.objects.load(tree.tree.sha, a, io)) |rt| switch (rt) {
            .tree => |t| t.withPath(path),
            else => return error.InvalidSha,
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

    pub fn iterate(tree: *const Path) Iterator {
        return tree.tree.iterate();
    }

    pub fn getRoot(tree: *const Path) !void {
        _ = tree;
        return error.NetImplemented;
    }

    pub fn raze(tree: *const Path, a: Allocator) void {
        a.free(tree.path);
        tree.raze(a);
    }
};

pub fn init(sha: Sha, blob: []const u8) !Tree {
    return .{ .sha = sha, .bytes = blob };
}

pub fn initSha(sha: Sha, repo: *const Repo, a: Allocator, io: Io) !Tree {
    const new = try repo.objects.load(sha, a, io);
    if (new != .tree) return error.NotATree;
    return new.tree;
}

pub fn initAlloc(sha: Sha, body: []const u8, a: Allocator) !Tree {
    const blob = try a.dupe(u8, body);
    return .{ .sha = sha, .bytes = blob };
}

pub fn descend(tree: *const Tree, path: []const u8, repo: *const Repo, a: Allocator, io: Io) !Path {
    var path_itr = std.fs.path.componentIterator(path);
    const first = path_itr.first();
    const rest = if (path_itr.peekNext()) |_|
        path_itr.path[path_itr.start_index..]
    else
        &.{};

    var itr = tree.iterate();
    while (itr.next()) |next| {
        if (eql(u8, next.name, first)) {
            const new = try repo.objects.load(tree.sha, a, io);
            if (new != .tree) return error.NotATree;

            if (rest.len > 0) {
                return try (Path{
                    .tree = new.tree,
                    .parent = tree,
                    .path = first,
                }).descend(rest, repo, a, io);
            }
            return .{
                .tree = new.tree,
                .parent = tree,
                .path = first,
            };
        }
    }
    return error.NotFound;
}

pub fn withPath(tree: Tree, path: []const u8) Tree.Path {
    return .{
        .tree = tree,
        .parent = null,
        .path = path,
    };
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

    //return countScalar(u8, tree.blob, 0);
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
    return self.changedSetFrom(repo, head.sha, a, io);
}

pub fn changedSetFrom(self: Tree, repo: *const Repo, start_commit: Sha, a: Allocator, io: Io) ![]ChangeSet {
    const search_list: []?Blob = try a.alloc(?Blob, self.count());
    var itr = self.iterate();
    for (search_list) |*dst| dst.* = itr.next() orelse unreachable;

    defer a.free(search_list);

    var par = switch (try repo.objects.load(start_commit, a, io)) {
        .commit => |c| c,
        else => unreachable,
    };

    var ptree = try initSha(par.sha, repo, a, io);

    var changed = try a.alloc(ChangeSet, self.count());
    var old = par;
    var oldtree = ptree;
    var found: usize = 0;
    while (found < search_list.len) {
        old = par;
        oldtree = ptree;
        par = par.toParent(0, repo, a, io) catch |err| switch (err) {
            error.NoParent, error.IncompleteObject => {
                for (search_list, 0..) |search_ish, i| {
                    if (search_ish) |search| {
                        found += 1;
                        changed[i] = try .init(a, search.name, old);
                    }
                }
                old.raze(a);
                oldtree.raze(a);
                break;
            },
            else => |e| return e,
        };
        ptree = initSha(par.sha, repo, a, io) catch |err| switch (err) {
            error.IncompleteObject => {
                for (search_list, 0..) |search_ish, i| {
                    if (search_ish) |search| {
                        found += 1;
                        changed[i] = try .init(a, search.name, old);
                    }
                }
                old.raze(a);
                oldtree.raze(a);
                break;
            },
            else => |e| return e,
        };
        for (search_list, 0..) |*search_ish, i| {
            const search = search_ish.* orelse continue;
            const sha_bin: []const u8 = switch (search.sha.hash) {
                .sha1 => |sh| &sh,
                .sha256 => |sh| &sh,
                .partial => unreachable,
            };
            if (find(u8, ptree.bytes, sha_bin) == null) {
                search_ish.* = null;
                found += 1;
                changed[i] = try .init(a, search.name, old);
                continue;
            }
        }
        old.raze(a);
        oldtree.raze(a);
    }

    par.raze(a);
    ptree.raze(a);
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
    var a = std.testing.allocator;
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

    const csubtree = (try initSha(cmtt.sha, &repo, a, io)).withPath("src");
    if (false) std.debug.print("{any}\n", .{csubtree});
    csubtree.raze(a);

    const csubtree2 = (try initSha(cmtt.sha, &repo, a, io)).withPath("src/endpoints");
    if (false) std.debug.print("{any}\n", .{csubtree2});
    if (false) for (csubtree2.objects) |obj|
        std.debug.print("{any}\n", .{obj});
    defer csubtree2.raze(a);

    const changed = try csubtree2.tree.changedSet(&repo, a, io);
    var subitr2 = csubtree2.iterate();
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
