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

const Pack = extern struct {
    sig: u32 = 0,
    vnum: u32 = 0,
    onum: u32 = 0,
};

/// Packfile v2 support only at this time
/// marked as extern to enable mmaping the header if useful
const PackIdxHeader = extern struct {
    magic: u32,
    vnum: u32,
    fanout: [256]u32,
};

const PackIdx = struct {
    header: PackIdxHeader,
    objnames: ?[]u8 = null,
    crc: ?[]u32 = null,
    offsets: ?[]u32 = null,
    hugeoffsets: ?[]u64 = null,
};

const PackObjType = enum(u3) {
    invalid = 0,
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,
};

pub const Repo = struct {
    dir: std.fs.Dir,
    packs: []PackIdx,

    pub fn init(d: std.fs.Dir) !Repo {
        var repo = Repo{
            .dir = d,
            .packs = undefined,
        };
        repo.packs.len = 0;
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

    const empty_sha = [_]u8{0} ** 20;

    pub fn openObj(self: *Repo, in_sha: SHA) !std.fs.File {
        var sha: [40]u8 = undefined;
        if (in_sha.len == 20) {
            _ = try std.fmt.bufPrint(&sha, "{}", .{hexLower(in_sha)});
        } else if (in_sha.len > 40) {
            unreachable;
        } else {
            @memcpy(&sha, in_sha);
        }
        var fb = [_]u8{0} ** 2048;
        var filename = try std.fmt.bufPrint(&fb, "./objects/{s}/{s}", .{ sha[0..2], sha[2..] });
        return self.dir.openFile(filename, .{}) catch {
            filename = try std.fmt.bufPrint(&fb, "./objects/{s}", .{sha});
            return self.dir.openFile(filename, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    std.debug.print("unable to find commit '{s}'\n", .{sha});
                    return err;
                },
                else => return err,
            };
        };
    }

    fn readPackIdx(self: *Repo, a: Allocator) !void {
        var idir = try self.dir.openIterableDir("./objects/pack", .{});
        var itr = idir.iterate();
        var i: usize = 0;
        while (try itr.next()) |file| {
            if (!std.mem.eql(u8, file.name[file.name.len - 4 ..], ".idx")) continue;
            i += 1;
        }
        self.packs = try a.alloc(PackIdx, i);
        itr.reset();
        i = 0;
        while (try itr.next()) |file| {
            if (!std.mem.eql(u8, file.name[file.name.len - 4 ..], ".idx")) continue;
            var filename = try std.fmt.allocPrint(a, "./objects/pack/{s}", .{file.name});
            defer a.free(filename);
            var fd = try self.dir.openFile(filename, .{});
            defer fd.close();
            var freader = fd.reader();
            var header = &self.packs[i].header;
            header.magic = try freader.readIntBig(u32);
            header.vnum = try freader.readIntBig(u32);
            header.fanout = undefined;
            for (&header.fanout) |*fo| {
                fo.* = try freader.readIntBig(u32);
            }
            var pack = &self.packs[i];
            pack.objnames = try a.alloc(u8, 20 * header.fanout[255]);
            pack.crc = try a.alloc(u32, header.fanout[255]);
            pack.offsets = try a.alloc(u32, header.fanout[255]);
            pack.hugeoffsets = null;

            _ = try freader.read(pack.objnames.?[0 .. 20 * header.fanout[255]]);
            for (pack.crc.?) |*crc| {
                crc.* = try freader.readIntNative(u32);
            }
            for (pack.offsets.?) |*crc| {
                crc.* = try freader.readIntBig(u32);
            }

            i += 1;
        }
    }

    fn findPacks(self: *Repo, a: Allocator) !void {
        var idir = try self.dir.openIterableDir("./objects/pack", .{});
        var itr = idir.iterate();
        while (try itr.next()) |file| {
            if (file.name[file.name.len - 1] == 'x') continue;
            //std.debug.print("{s}\n", .{file.name});
            var filename = try std.fmt.allocPrint(a, "./objects/pack/{s}", .{file.name});
            defer a.free(filename);
            var fd = try self.dir.openFile(filename, .{});
            defer fd.close();
            var freader = fd.reader();
            var vpack = Pack{
                .sig = try freader.readIntBig(u32),
                .vnum = try freader.readIntBig(u32),
                .onum = try freader.readIntBig(u32),
            };
            _ = vpack;
            //std.debug.print("{}\n", .{vpack});

            var buf = [_]u8{0};
            var cont: bool = false;

            _ = try freader.read(&buf);
            cont = buf[0] >= 128;
            const objtype: PackObjType = @enumFromInt((buf[0] & 0b01110000) >> 4);
            var objsize: usize = 0;

            if (cont) {
                _ = try freader.read(&buf);
                objsize |= @as(u16, buf[0]) << 4;
                cont = buf[0] >= 128;
                std.debug.assert(!cont); // not implemented
            }
            var pack1 = try a.alloc(u8, objsize);
            defer a.free(pack1);
            _ = try freader.read(pack1);

            switch (objtype) {
                .tree => {
                    //var cmt = try Tree.fromPack(a, pack1);
                    //std.debug.print("{}\n", .{cmt});
                    //for (cmt.objects) |obj| {
                    //    std.debug.print("{s} {}\n", .{ obj.name, obj });
                    //}
                },
                else => {},
            }

            break;
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
            if (file.kind != .file) {
                std.log.info("Not desending {s}", .{file.name});
                continue;
            }
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
        const cmt = try Commit.fromFile(a, sha.branch.sha, try self.openObj(sha.branch.sha));
        return try Tree.fromRepo(a, self, cmt.tree);
    }

    pub fn commit(self: *Repo, a: Allocator) !Commit {
        var ref_main = try self.dir.openFile("./refs/heads/main", .{});
        var b: [1 << 16]u8 = undefined;
        var head = try ref_main.read(&b);
        var file = try self.openObj(b[0 .. head - 1]);
        var cmt = try Commit.fromFile(a, b[0 .. head - 1], file);
        cmt.repo = self;
        return cmt;
    }

    pub fn raze(self: *Repo, a: Allocator) void {
        self.dir.close();
        for (self.packs) |pack| {
            a.free(pack.objnames.?);
            a.free(pack.crc.?);
            a.free(pack.offsets.?);
            // a.free(pack.hugeoffsets); // not implemented
        }
        a.free(self.packs);
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

pub const Commit = struct {
    blob: []const u8,
    sha: SHA,
    tree: SHA,
    parent: [3]?SHA,
    author: Actor,
    committer: Actor,
    message: []const u8,
    repo: ?*Repo = null,

    ptr_parent: ?*Commit = null, // TOOO multiple parents

    fn header(self: *Commit, data: []const u8) !void {
        if (std.mem.indexOf(u8, data, " ")) |brk| {
            const name = data[0..brk];
            const payload = data[brk..];
            if (std.mem.eql(u8, name, "commit")) {
                if (std.mem.indexOf(u8, data, "\x00")) |nl| {
                    self.tree = payload[nl..][0..40];
                } else unreachable;
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
            } else return error.UnknownHeader;
        } else return error.MalformedHeader;
    }

    pub fn make(sha: SHA, data: []const u8) !Commit {
        var lines = std.mem.split(u8, data, "\n");
        var self: Commit = undefined;
        self.repo = null;
        self.parent = .{ null, null, null }; // I don't like it either, but... lazy
        self.blob = data;
        while (lines.next()) |line| {
            if (line.len == 0) break;
            try self.header(line);
        }
        self.message = lines.rest();
        self.sha = sha;
        return self;
    }

    pub fn fromFile(a: Allocator, sha: SHA, file: std.fs.File) !Commit {
        var d = try zlib.decompressStream(a, file.reader());
        defer d.deinit();
        var buf = try a.alloc(u8, 1 << 16);
        const count = try d.read(buf);
        if (count == 1 << 16) return error.FileDataTooLarge;
        var self = try make(sha, buf[0..count]);
        self.blob = buf;
        self.sha = sha;
        return self;
    }

    pub fn toParent(self: *Commit, a: Allocator, idx: u8) !Commit {
        if (idx >= self.parent.len) return error.NoParent;
        if (self.parent[idx]) |parent| {
            if (self.repo) |repo| {
                var file = try repo.openObj(parent);
                defer file.close();
                var cmt = try Commit.fromFile(a, parent, file);
                cmt.repo = repo;
                return cmt;
            }
            return error.DetachedCommit;
        }
        return error.NoParent;
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
        var file = try r.openObj(sha);
        var d = try zlib.decompressStream(a, file.reader());
        defer d.deinit();
        var count = try d.read(&b);
        return try Tree.make(a, b[0..count]);
    }

    pub fn fromPack(a: Allocator, cblob: []const u8) !Tree {
        var al = std.ArrayList(u8).init(a);
        var fbs = std.io.fixedBufferStream(cblob);
        var d = try zlib.decompressStream(a, fbs.reader());
        defer d.deinit();
        try d.reader().readAllArrayList(&al, 65536);
        return try Tree.make(a, try al.toOwnedSlice());
    }

    pub fn make(a: Allocator, blob: []const u8) !Tree {
        var self: Tree = .{
            .blob = blob,
            .objects = try a.alloc(Blob, std.mem.count(u8, blob, "\x00")),
        };

        var i: usize = 0;
        if (std.mem.indexOf(u8, blob, "tree ")) |tidx| {
            if (std.mem.indexOfScalarPos(u8, blob, i, 0)) |index| {
                // This is probably wrong for large trees, but #YOLO
                std.debug.assert(tidx == 0);
                std.debug.assert(std.mem.eql(u8, "tree ", blob[0..5]));
                std.debug.assert(index == 8);

                i = 9;
            }
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
    const commit = try Commit.make("370303630b3fc631a0cb3942860fb6f77446e9c1", b[0..count]);
    //std.debug.print("{}\n", .{commit});
    try std.testing.expectEqualStrings("fcb6817b0efc397f1525ff7ee375e08703ed17a9", commit.tree);
    try std.testing.expectEqualStrings("370303630b3fc631a0cb3942860fb6f77446e9c1", commit.sha);
}

test "file" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./.git/objects/37/0303630b3fc631a0cb3942860fb6f77446e9c1", .{});
    const commit = try Commit.fromFile(a, "370303630b3fc631a0cb3942860fb6f77446e9c1", file);
    defer a.free(commit.blob);
    //std.debug.print("{}\n", .{commit});
    try std.testing.expectEqualStrings("fcb6817b0efc397f1525ff7ee375e08703ed17a9", commit.tree);
    try std.testing.expectEqualStrings("370303630b3fc631a0cb3942860fb6f77446e9c1", commit.sha);
}

test "toParent" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();

    var repo = try Repo.init(cwd);
    var commit = try repo.commit(a);

    var count: usize = 0;
    while (true) {
        count += 1;
        const old = commit.blob;
        if (commit.parent[0]) |_| {
            commit = try commit.toParent(a, 0);
        } else break;

        a.free(old);
    }
    a.free(commit.blob);
    try std.testing.expect(count >= 31); // LOL SORRY!
}

test "tree" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./.git/objects/37/0303630b3fc631a0cb3942860fb6f77446e9c1", .{});
    const commit = try Commit.fromFile(a, "370303630b3fc631a0cb3942860fb6f77446e9c1", file);
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

test "read pack" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();

    var dir = try cwd.openDir("repos/hastur", .{});

    var repo = try Repo.init(dir);

    try repo.findPacks(a);
    try repo.readPackIdx(a);
    repo.raze(a);
}
