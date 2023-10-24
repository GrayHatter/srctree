const std = @import("std");

const Allocator = std.mem.Allocator;
const zlib = std.compress.zlib;
const hexLower = std.fmt.fmtSliceHexLower;

const DateTime = @import("datetime.zig");

const Types = enum {
    commit,
    blob,
    tree,
};

const SHA = []const u8; // SUPERBAD, I'm sorry!

const empty_sha = [_]u8{0} ** 20;

fn openObj(d: std.fs.Dir, in_sha: SHA) !std.fs.File {
    var sha: [40]u8 = undefined;
    if (in_sha.len == 20) {
        _ = try std.fmt.bufPrint(&sha, "{}", .{hexLower(in_sha)});
    } else {
        @memcpy(&sha, in_sha);
    }
    var fb = [_]u8{0} ** 2048;
    var filename = try std.fmt.bufPrint(&fb, "./objects/{s}/{s}", .{ sha[0..2], sha[2..] });
    return d.openFile(filename, .{}) catch {
        filename = try std.fmt.bufPrint(&fb, "./objects/{s}", .{sha});
        return try d.openFile(filename, .{});
    };
}

pub const Repo = struct {
    dir: std.fs.Dir,

    pub fn init(d: std.fs.Dir) !Repo {
        var repo = .{
            .dir = d,
        };

        if (d.openFile("./HEAD", .{})) |file| {
            file.close();
        } else |_| {
            if (d.openDir("./.git", .{})) |full| {
                if (full.openFile("./HEAD", .{})) |file| {
                    file.close();
                    repo.dir = full;
                } else |_| return error.NotAGitRepo;
            } else |_| return error.NotAGitRepo;
        }

        return repo;
    }

    fn findPacks(self: *Repo) !void {
        var idir = try self.dir.openIterableDir("./objects/pack", .{});
        var itr = idir.iterate();
        while (try itr.next()) |file| {
            std.debug.print("{s}\n", .{file.name});
        }
    }

    fn readPack() void {}

    /// API may disappear
    pub fn objectsDir(self: *Repo) !std.fs.Dir {
        return try self.dir.openDir("./objects/", .{});
    }

    pub fn deref() Object {}

    /// Caller owns memory
    pub fn refs(self: Repo, a: Allocator) ![]Ref {
        var list = std.ArrayList(Ref).init(a);
        var idir = try self.dir.openIterableDir("refs/heads", .{});
        var itr = idir.iterate();
        while (try itr.next()) |file| {
            var filename = [_]u8{0} ** 2048;
            var fname: []u8 = &filename;
            fname = try std.fmt.bufPrint(&filename, "./refs/heads/{s}", .{file.name});
            var f = try self.dir.openFile(fname, .{});
            var buf: [40]u8 = undefined;
            var read = try f.readAll(&buf);
            std.debug.assert(read == 40);
            try list.append(Ref{ .branch = .{
                .name = try a.dupe(u8, file.name),
                .sha = try a.dupe(u8, &buf),
            } });
        }
        if (self.dir.openFile("packed-refs", .{})) |file| {
            var buf: [2048]u8 = undefined;
            var size = try file.readAll(&buf);
            const b = buf[0..size];
            var p_itr = std.mem.split(u8, b, "\n");
            _ = p_itr.next();
            while (p_itr.next()) |line| {
                if (std.mem.indexOf(u8, line, "refs/heads")) |_| {
                    try list.append(Ref{ .branch = .{
                        .name = try a.dupe(u8, line[52..]),
                        .sha = try a.dupe(u8, line[0..40]),
                    } });
                }
            }
        } else |_| {}
        return try list.toOwnedSlice();
    }

    /// TODO write the real function that goes here
    pub fn ref(self: *Repo, a: Allocator, str: []const u8) !SHA {
        var lrefs = try self.refs(a);
        for (lrefs) |r| {
            switch (r) {
                .tag => unreachable,
                .branch => |b| {
                    if (std.mem.eql(u8, b.name, str)) {
                        return try a.dupe(u8, b.sha);
                    }
                },
            }
        }
        return error.RefMissing;
    }

    pub fn resolve(self: *Repo, r: Ref) !SHA {
        switch (r) {
            .tag => unreachable,
            .branch => {
                return try self.ref(r);
            },
        }
    }

    /// TODO I don't want this to take an allocator :(
    pub fn HEAD(self: *Repo, a: Allocator) !Ref {
        var f = try self.dir.openFile("HEAD", .{});
        defer f.close();
        var name = try f.readToEndAlloc(a, 1 <<| 18);
        if (!std.mem.eql(u8, name[0..5], "ref: ")) {
            std.debug.print("unexpected HEAD {s}\n", .{name});
            unreachable;
        }

        return .{
            .branch = Branch{
                .name = name[5..],
                .sha = try self.ref(a, name[16 .. name.len - 1]),
                .repo = self,
            },
        };
    }

    pub fn tree(self: *Repo, a: Allocator) !Tree {
        const sha = try self.HEAD(a);
        const cmt = try Commit.readFile(a, try openObj(self.dir, sha.branch.sha));
        return try Tree.fromRepo(a, self, cmt.sha);
    }

    pub fn commit(self: *Repo, a: Allocator) !Commit {
        var ref_main = try self.dir.openFile("./refs/heads/main", .{});
        var b: [1 << 16]u8 = undefined;
        var head = try ref_main.read(&b);
        var file = try openObj(self.dir, b[0 .. head - 1]);
        return try Commit.readFile(a, file);
    }

    pub fn raze(self: *Repo) void {
        self.dir.close();
    }
};

pub const Branch = struct {
    name: []const u8,
    sha: SHA,
    repo: ?*const Repo = null,
};

pub const Tag = struct {
    name: []const u8,
    sha: SHA,
};

pub const Ref = union(enum) {
    tag: Tag,
    branch: Branch,
};

const Actor = struct {
    name: []const u8,
    email: []const u8,
    time: DateTime,

    pub fn make(data: []const u8) !Actor {
        var itr = std.mem.splitBackwards(u8, data, " ");
        const tzstr = itr.next() orelse return error.ActorParseError;
        const epoch = itr.next() orelse return error.ActorParseError;
        const time = try DateTime.fromEpochTzStr(epoch, tzstr);
        const email = itr.next() orelse return error.ActorParseError;
        const name = itr.rest();

        return .{
            .name = name,
            .email = email,
            .time = time,
        };
    }

    pub fn format(self: Actor, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        try out.print("Actor{{ name {s}, email {s} time {} }}", .{ self.name, self.email, self.time });
    }
};

pub fn toParent(a: Allocator, parent: SHA, objs: std.fs.Dir) !Commit {
    var fb = [_]u8{0} ** 2048;
    const filename = try std.fmt.bufPrint(&fb, "{s}/{s}", .{ parent[1..3], parent[3..] });
    var file = try objs.openFile(filename, .{});
    defer file.close();
    return Commit.readFile(a, file);
}

pub const Commit = struct {
    blob: []const u8,
    sha: SHA,
    parent: [3]?SHA,
    author: Actor,
    committer: Actor,
    message: []const u8,
    repo: ?*const Repo = null,

    ptr_parent: ?*Commit = null, // TOOO multiple parents

    fn header(self: *Commit, data: []const u8) !void {
        if (std.mem.indexOf(u8, data, " ")) |brk| {
            const name = data[0..brk];
            const payload = data[brk..];
            if (std.mem.eql(u8, name, "commit")) {
                if (std.mem.indexOf(u8, data, "\x00")) |nl| {
                    self.sha = payload[nl..][0..40];
                } else unreachable;
            } else if (std.mem.eql(u8, name, "parent")) {
                for (&self.parent) |*parr| {
                    if (parr.* == null) {
                        parr.* = payload;
                        return;
                    }
                }
            } else if (std.mem.eql(u8, name, "author")) {
                self.author = try Actor.make(payload);
            } else if (std.mem.eql(u8, name, "committer")) {
                self.committer = try Actor.make(payload);
            } else return error.UnknownHeader;
        } else return error.MalformedHeader;
    }

    pub fn make(data: []const u8) !Commit {
        var lines = std.mem.split(u8, data, "\n");
        var self: Commit = undefined;
        self.parent = .{ null, null, null }; // I don't like it either, but... lazy
        self.blob = data;
        while (lines.next()) |line| {
            if (line.len == 0) break;
            try self.header(line);
        }
        self.message = lines.rest();
        return self;
    }

    pub fn readFile(a: Allocator, file: std.fs.File) !Commit {
        var d = try zlib.decompressStream(a, file.reader());
        defer d.deinit();
        var buf = try a.alloc(u8, 1 << 16);
        const count = try d.read(buf);
        if (count == 1 << 16) return error.FileDataTooLarge;
        var self = try make(buf[0..count]);
        self.blob = buf;
        return self;
    }

    pub fn format(self: Commit, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        try out.print(
            \\Commit{{
            \\commit {s}
            \\
        , .{self.sha});
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
};

pub const Object = union(enum) {
    blob: Blob,
    tree: Tree,
    commit: Commit,
    ref: Ref,
};

pub const Blob = struct {
    mode: [6]u8,
    name: []const u8,
    hash: [40]u8,
};

pub const Tree = struct {
    blob: []const u8,
    objects: []Blob,

    pub fn fromRepo(a: Allocator, r: *Repo, sha: SHA) !Tree {
        var b: [1 << 16]u8 = undefined;
        var file = try openObj(r.dir, sha);
        var d = try zlib.decompressStream(a, file.reader());
        defer d.deinit();
        var count = try d.read(&b);
        return try Tree.make(a, b[0..count]);
    }

    pub fn make(a: Allocator, blob: []const u8) !Tree {
        var self: Tree = .{
            .blob = blob,
            .objects = try a.alloc(Blob, std.mem.count(u8, blob, "\x00")),
        };

        var i: usize = 0;
        if (std.mem.indexOfScalarPos(u8, blob, i, 0)) |index| {
            // This is probably wrong for large trees, but #YOLO
            std.debug.assert(std.mem.eql(u8, "tree ", blob[0..5]));
            std.debug.assert(index == 8);
            i = 9;
        }
        var obj_i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, blob, i, 0)) |index| {
            var obj = &self.objects[obj_i];
            obj_i += 1;
            if (blob[i] == '1') {
                _ = try std.fmt.bufPrint(&obj.mode, "{s}", .{blob[i .. i + 6]});
                _ = try std.fmt.bufPrint(&obj.hash, "{}", .{hexLower(blob[index + 1 .. index + 21])});
                obj.name = blob[i + 7 .. index];
            } else if (blob[i] == '4') {
                _ = try std.fmt.bufPrint(&obj.mode, "0{s}", .{blob[i .. i + 5]});
                _ = try std.fmt.bufPrint(&obj.hash, "{}", .{hexLower(blob[index + 1 .. index + 21])});
                obj.name = blob[i + 6 .. index];
            } else std.debug.print("panic {s} ", .{blob[i..index]});

            i = index + 21;
        }
        if (a.resize(self.objects, obj_i)) {
            self.objects.len = obj_i;
        }
        return self;
    }
};

test "read" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./.git/objects/37/0303630b3fc631a0cb3942860fb6f77446e9c1", .{});
    var b: [1 << 16]u8 = undefined;

    var d = try zlib.decompressStream(a, file.reader());
    defer d.deinit();
    var count = try d.read(&b);
    //std.debug.print("{s}\n", .{b[0..count]});
    const commit = try Commit.make(b[0..count]);
    //std.debug.print("{}\n", .{commit});
    try std.testing.expectEqualStrings("fcb6817b0efc397f1525ff7ee375e08703ed17a9", commit.sha);
}

test "file" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./.git/objects/37/0303630b3fc631a0cb3942860fb6f77446e9c1", .{});
    const commit = try Commit.readFile(a, file);
    defer a.free(commit.blob);
    //std.debug.print("{}\n", .{commit});
    try std.testing.expectEqualStrings("fcb6817b0efc397f1525ff7ee375e08703ed17a9", commit.sha);
}

test "toParent" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();
    var dir = try cwd.openDir("./.git/objects/", .{});
    defer dir.close();

    var ref_main = try cwd.openFile("./.git/refs/heads/main", .{});
    var b: [1 << 16]u8 = undefined;
    var head = try ref_main.read(&b);

    var fb = [_]u8{0} ** 2048;
    var filename = try std.fmt.bufPrint(&fb, "./.git/objects/{s}/{s}", .{ b[0..2], b[2 .. head - 1] });
    var file = try cwd.openFile(filename, .{});
    var commit = try Commit.readFile(a, file);
    defer a.free(commit.blob);

    var count: usize = 0;
    while (true) {
        count += 1;
        const old = commit.blob;
        if (commit.parent[0]) |parent| {
            commit = try toParent(a, parent, dir);
        } else break;

        a.free(old);
    }
    try std.testing.expect(count >= 31); // LOL SORRY!
}

test "tree" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./.git/objects/37/0303630b3fc631a0cb3942860fb6f77446e9c1", .{});
    const commit = try Commit.readFile(a, file);
    defer a.free(commit.blob);
    //std.debug.print("tree {s}\n", .{commit.sha});
}

test "tree decom" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./.git/objects/5e/dabf724389ef87fa5a5ddb2ebe6dbd888885ae", .{});
    var b: [1 << 16]u8 = undefined;

    var d = try zlib.decompressStream(a, file.reader());
    defer d.deinit();
    var count = try d.read(&b);
    var tree = try Tree.make(a, b[0..count]);
    defer a.free(tree.objects);
    for (tree.objects) |_| {
        //std.debug.print("{s} {s} {s}\n", .{ obj.mode, obj.hash, obj.name });
    }
    //std.debug.print("{}\n", .{tree});
}

test "tree child" {
    var a = std.testing.allocator;
    var child = try std.ChildProcess.exec(.{
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

test "read pack" {}
