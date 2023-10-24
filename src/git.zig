const std = @import("std");

const Allocator = std.mem.Allocator;
const zlib = std.compress.zlib;

const DateTime = @import("datetime.zig");

const Types = enum {
    commit,
    blob,
    tree,
};

const SHA = []const u8; // SUPERBAD, I'm sorry!

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

    /// API may disappear
    pub fn objectsDir(self: *Repo) !std.fs.Dir {
        return try self.dir.openDir("./objects/", .{});
    }

    pub fn deref() Object {}

    /// Caller owns memory
    pub fn refs(self: Repo, a: Allocator) ![][]u8 {
        var list = std.ArrayList([]u8).init(a);
        var idir = try self.dir.openIterableDir("refs/heads", .{});
        var itr = idir.iterate();
        while (try itr.next()) |file| {
            try list.append(try a.dupe(u8, file.name));
        }
        return try list.toOwnedSlice();
    }

    /// TODO I don't want this to take an allocator :(
    pub fn HEAD(self: *Repo, a: Allocator) ![]u8 {
        var f = try self.dir.openFile("HEAD", .{});
        defer f.close();
        var name = try f.readToEndAlloc(a, 1 <<| 18);
        return name;
    }

    pub fn headCommit(self: *Repo, a: Allocator) !Commit {
        var ref_main = try self.dir.openFile("./refs/heads/main", .{});
        var b: [1 << 16]u8 = undefined;
        var head = try ref_main.read(&b);

        var fb = [_]u8{0} ** 2048;
        var filename = try std.fmt.bufPrint(&fb, "./objects/{s}/{s}", .{ b[0..2], b[2 .. head - 1] });
        var file = try self.dir.openFile(filename, .{});
        return try Commit.readFile(a, file);
    }

    pub fn raze(self: *Repo) void {
        self.dir.close();
    }
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

    ptr_parent: ?*Commit = null, // TOOO multiple parents

    fn header(self: *Commit, data: []const u8) !void {
        if (std.mem.indexOf(u8, data, " ")) |brk| {
            const name = data[0..brk];
            const payload = data[brk..];
            if (std.mem.eql(u8, name, "commit")) {
                self.sha = payload;
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
    tag: Tag,
};

pub const Tag = struct {};

pub const Blob = struct {
    mode: [6]u8,
    name: []const u8,
    hash: [40]u8,
};

pub const Tree = struct {
    blob: []const u8,
    objects: []Blob,

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
                _ = try std.fmt.bufPrint(&obj.hash, "{}", .{std.fmt.fmtSliceHexLower(blob[index + 1 .. index + 21])});
                obj.name = blob[i + 7 .. index];
            } else if (blob[i] == '4') {
                _ = try std.fmt.bufPrint(&obj.mode, "0{s}", .{blob[i .. i + 5]});
                _ = try std.fmt.bufPrint(&obj.hash, "{}", .{std.fmt.fmtSliceHexLower(blob[index + 1 .. index + 21])});
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
    try std.testing.expectEqualStrings("fcb6817b0efc397f1525ff7ee375e08703ed17a9", commit.sha[10..]);
}

test "file" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./.git/objects/37/0303630b3fc631a0cb3942860fb6f77446e9c1", .{});
    const commit = try Commit.readFile(a, file);
    defer a.free(commit.blob);
    //std.debug.print("{}\n", .{commit});
    try std.testing.expectEqualStrings("fcb6817b0efc397f1525ff7ee375e08703ed17a9", commit.sha[10..]);
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
