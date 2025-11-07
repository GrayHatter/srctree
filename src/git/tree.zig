alloc: Allocator,
memory: ?[]u8 = null,
sha: SHA,
path: ?[]const u8 = null,
blob: []const u8,
blobs: []Blob,

const Tree = @This();

pub fn pushPath(self: *Tree, a: Allocator, path: []const u8) !void {
    const spath = self.path orelse {
        self.path = try a.dupe(u8, path);
        return;
    };

    self.path = try std.mem.join(a, "/", &[_][]const u8{ spath, path });
    a.free(spath);
}

pub fn init(sha: SHA, a: Allocator, blob: []const u8) !Tree {
    var self: Tree = .{
        .alloc = a,
        .sha = sha,
        .blob = blob,
        .blobs = try a.alloc(Blob, std.mem.count(u8, blob, "\x00")),
    };

    var i: usize = 0;
    if (std.mem.indexOf(u8, blob, "tree ")) |tidx| {
        if (std.mem.indexOfScalarPos(u8, blob, i, 0)) |index| {
            // This is probably wrong for large trees, but #YOLO
            std.debug.assert(tidx == 0);
            std.debug.assert(std.mem.eql(u8, "tree ", blob[0..5]));
            i = index + 1;
        }
    }
    var real_count: usize = 0;
    while (std.mem.indexOfScalarPos(u8, blob, i, 0)) |str_end| {
        var mode: [6]u8 = @splat('0');
        var name = blob[i + 7 .. str_end];
        if (blob[i] == '1') {
            @memcpy(mode[0..6], blob[i..][0..6]);
        } else if (blob[i] == '4') {
            @memcpy(mode[1..6], blob[i..][0..5]);
            name = blob[i + 6 .. str_end];
        }
        self.blobs[real_count] = .{
            .mode = mode,
            .name = name,
            .sha = .init(blob[str_end + 1 ..][0..20]),
        };
        real_count += 1;
        i = str_end + 21;
    }

    if (a.resize(self.blobs, real_count)) {
        self.blobs.len = real_count;
    } else {
        self.blobs = try a.realloc(self.blobs, real_count);
    }
    return self;
}

pub fn initOwned(sha: SHA, a: Allocator, body: []const u8, memory: []u8) !Tree {
    var tree = try init(sha, a, body);
    tree.memory = memory;
    return tree;
}

pub fn changedSet(self: Tree, repo: *const Repo, a: Allocator, io: Io) ![]ChangeSet {
    return self.changedSetFrom(repo, try repo.headSha(), a, io);
}

pub fn changedSetFrom(self: Tree, repo: *const Repo, start_commit: SHA, a: Allocator, io: Io) ![]ChangeSet {
    const search_list: []?Blob = try a.alloc(?Blob, self.blobs.len);
    for (search_list, self.blobs) |*dst, src| {
        dst.* = src;
    }
    defer a.free(search_list);

    var par = switch (try repo.loadObject(start_commit, a, io)) {
        .commit => |c| c,
        else => unreachable,
    };
    var ptree = try par.mkSubTree(self.path, repo, a, io);

    var changed = try a.alloc(ChangeSet, self.blobs.len);
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
                old.raze();
                oldtree.raze();
                break;
            },
            else => |e| return e,
        };
        ptree = par.mkSubTree(self.path, repo, a, io) catch |err| switch (err) {
            error.PathNotFound, error.IncompleteObject => {
                for (search_list, 0..) |search_ish, i| {
                    if (search_ish) |search| {
                        found += 1;
                        changed[i] = try .init(a, search.name, old);
                    }
                }
                old.raze();
                oldtree.raze();
                break;
            },
            else => |e| return e,
        };
        for (search_list, 0..) |*search_ish, i| {
            const search = search_ish.* orelse continue;
            if (std.mem.indexOf(u8, ptree.blob, &search.sha.bin)) |_| {} else {
                search_ish.* = null;
                found += 1;
                changed[i] = try .init(a, search.name, old);
                continue;
            }
        }
        old.raze();
        oldtree.raze();
    }

    par.raze();
    ptree.raze();
    return changed;
}

pub fn raze(self: Tree) void {
    if (self.path) |p| self.alloc.free(p);
    if (self.memory) |m| self.alloc.free(m);
    self.alloc.free(self.blobs);
}

pub fn format(self: Tree, out: *Io.Writer) !void {
    var f: usize = 0;
    var d: usize = 0;
    for (self.blobs) |obj| {
        if (obj.mode[0] == 48)
            d += 1
        else
            f += 1;
    }
    try out.print(
        \\Tree{{ {} Objects, {} files {} directories }}
    , .{ self.blobs.len, f, d });
}

test "tree decom" {
    var a = std.testing.allocator;
    const io = std.testing.io;

    var cwd = std.fs.cwd();
    var file = cwd.openFile(
        "./.git/objects/5e/dabf724389ef87fa5a5ddb2ebe6dbd888885ae",
        .{},
    ) catch |err| switch (err) {
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
    const blob = buf[(indexOf(u8, buf, "\x00") orelse unreachable) + 1 ..];
    //std.debug.print("{s}\n", .{buf});
    const tree = try Tree.init(SHA.init("5edabf724389ef87fa5a5ddb2ebe6dbd888885ae"), a, blob);
    defer tree.raze();
    for (tree.blobs) |tobj| {
        if (false) std.debug.print("{s} {s} {s}\n", .{ tobj.mode, tobj.hash, tobj.name });
    }
    if (false) std.debug.print("{}\n", .{tree});
}

test "tree child" {
    var a = std.testing.allocator;
    const child = try std.process.Child.run(.{
        .allocator = a,
        .argv = &[_][]const u8{
            "git",
            "cat-file",
            "-p",
            "5edabf724389ef87fa5a5ddb2ebe6dbd888885ae",
        },
    });
    //std.debug.print("{s}\n", .{child.stdout});
    a.free(child.stdout);
    a.free(child.stderr);
}

test "mk sub tree" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd.adaptToNewApi(), io);
    defer repo.raze(a, io);

    try repo.loadData(a, io);

    const cmtt = try repo.headCommit(a, io);
    defer cmtt.raze();

    var tree = try cmtt.loadTree(&repo, a, io);
    defer tree.raze();

    var blob: Blob = blb: for (tree.blobs) |obj| {
        if (std.mem.eql(u8, obj.name, "src")) break :blb obj;
    } else return error.ExpectedBlobMissing;
    var subtree = try blob.toTree(&repo, a, io);
    if (false) std.debug.print("{any}\n", .{subtree});
    for (subtree.blobs) |obj| {
        if (false) std.debug.print("{any}\n", .{obj});
    }

    subtree.raze();
}

test "commit mk sub tree" {
    var a = std.testing.allocator;
    const io = std.testing.io;

    const cwd = try Io.Dir.cwd().openDir(io, ".", .{});
    var repo = try Repo.init(cwd, io);
    defer repo.raze(a, io);

    try repo.loadData(a, io);

    const cmtt = try repo.headCommit(a, io);
    defer cmtt.raze();

    var tree = try cmtt.loadTree(&repo, a, io);
    defer tree.raze();

    var blob: Blob = blb: for (tree.blobs) |obj| {
        if (std.mem.eql(u8, obj.name, "src")) break :blb obj;
    } else return error.ExpectedBlobMissing;
    var subtree = try blob.toTree(&repo, a, io);
    if (false) std.debug.print("{any}\n", .{subtree});
    for (subtree.blobs) |obj| {
        if (false) std.debug.print("{any}\n", .{obj});
    }
    defer subtree.raze();

    const csubtree = try cmtt.mkSubTree("src", &repo, a, io);
    if (false) std.debug.print("{any}\n", .{csubtree});
    csubtree.raze();

    const csubtree2 = try cmtt.mkSubTree("src/endpoints", &repo, a, io);
    if (false) std.debug.print("{any}\n", .{csubtree2});
    if (false) for (csubtree2.objects) |obj|
        std.debug.print("{any}\n", .{obj});
    defer csubtree2.raze();

    const changed = try csubtree2.changedSet(&repo, a, io);
    for (csubtree2.blobs, changed) |o, c| {
        if (false) std.debug.print("{s} {s}\n", .{ o.name, c.sha });
        c.raze(a);
    }
    a.free(changed);
}

const SHA = @import("SHA.zig");
const Repo = @import("Repo.zig");
const Blob = @import("blob.zig");
const Commit = @import("Commit.zig");
const ChangeSet = @import("changeset.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const hexLower = std.fmt.fmtSliceHexLower;
const bufPrint = std.fmt.bufPrint;
const zstd = std.compress.zstd;
const indexOf = std.mem.indexOf;
