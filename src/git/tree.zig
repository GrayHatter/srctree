const std = @import("std");
const Allocator = std.mem.Allocator;
const hexLower = std.fmt.fmtSliceHexLower;
const bufPrint = std.fmt.bufPrint;

const Git = @import("../git.zig");
const SHA = Git.SHA;
const Repo = Git.Repo;
const Blob = @import("blob.zig");

const Tree = @This();

alloc: Allocator,
memory: ?[]u8 = null,
sha: SHA,
path: ?[]const u8 = null,
blob: []const u8,
blobs: []Blob,

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
    var obj_i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, blob, i, 0)) |index| {
        var obj = &self.blobs[obj_i];

        obj_i += 1;
        if (blob[i] == '1') {
            _ = try bufPrint(&obj.mode, "{s}", .{blob[i .. i + 6]});
            obj.sha = SHA.init(blob[index + 1 .. index + 21]);
            obj.name = blob[i + 7 .. index];
        } else if (blob[i] == '4') {
            _ = try bufPrint(&obj.mode, "0{s}", .{blob[i .. i + 5]});
            obj.sha = SHA.init(blob[index + 1 .. index + 21]);
            obj.name = blob[i + 6 .. index];
        } else std.debug.print("panic {s} ", .{blob[i..index]});

        i = index + 21;
    }
    if (a.resize(self.blobs, obj_i)) {
        self.blobs.len = obj_i;
    }
    return self;
}

pub fn initOwned(sha: SHA, a: Allocator, obj: Git.Object) !Tree {
    var tree = try init(sha, a, obj.body);
    tree.memory = obj.memory;
    return tree;
}

pub fn changedSet(self: Tree, a: Allocator, repo: *const Repo) ![]Git.ChangeSet {
    const cmtt = try repo.headCommit(a);
    defer cmtt.raze();
    const search_list: []?Blob = try a.alloc(?Blob, self.blobs.len);
    for (self.blobs, search_list) |src, *dst| {
        dst.* = src;
    }
    defer a.free(search_list);

    var par = try repo.headCommit(a);
    var ptree = try par.mkSubTree(a, self.path, repo);

    var changed = try a.alloc(Git.ChangeSet, self.blobs.len);
    var old = par;
    var oldtree = ptree;
    var found: usize = 0;
    while (found < search_list.len) {
        old = par;
        oldtree = ptree;
        par = par.toParent(a, 0, repo) catch |err| switch (err) {
            error.NoParent, error.IncompleteObject => {
                for (search_list, 0..) |search_ish, i| {
                    if (search_ish) |search| {
                        found += 1;
                        changed[i] = try Git.ChangeSet.init(
                            a,
                            search.name,
                            old.sha,
                            old.message,
                            old.committer.timestamp,
                        );
                    }
                }
                old.raze();
                oldtree.raze();
                break;
            },
            else => |e| return e,
        };
        ptree = par.mkSubTree(a, self.path, repo) catch |err| switch (err) {
            error.PathNotFound, error.IncompleteObject => {
                for (search_list, 0..) |search_ish, i| {
                    if (search_ish) |search| {
                        found += 1;
                        changed[i] = try Git.ChangeSet.init(
                            a,
                            search.name,
                            old.sha,
                            old.message,
                            old.committer.timestamp,
                        );
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
            var line = search.name;
            line.len += 21;
            line = line[line.len - 20 .. line.len];
            if (std.mem.indexOf(u8, ptree.blob, line)) |_| {} else {
                search_ish.* = null;
                found += 1;
                changed[i] = try Git.ChangeSet.init(
                    a,
                    search.name,
                    old.sha,
                    old.message,
                    old.committer.timestamp,
                );
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

pub fn format(self: Tree, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
    var f: usize = 0;
    var d: usize = 0;
    for (self.objects) |obj| {
        if (obj.mode[0] == 48)
            d += 1
        else
            f += 1;
    }
    try out.print(
        \\Tree{{ {} Objects, {} files {} directories }}
    , .{ self.objects.len, f, d });
}
