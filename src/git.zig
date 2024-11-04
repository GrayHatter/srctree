const std = @import("std");
const Allocator = std.mem.Allocator;
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const zlib = std.compress.zlib;
const hexLower = std.fmt.fmtSliceHexLower;
const bufPrint = std.fmt.bufPrint;
const AnyReader = std.io.AnyReader;

pub const Actor = @import("git/actor.zig");
pub const Agent = @import("git/agent.zig");
pub const Blob = @import("git/blob.zig");
pub const Commit = @import("git/commit.zig");
pub const Pack = @import("git/pack.zig");
pub const Tree = @import("git/tree.zig");

pub const Error = error{
    ReadError,
    NotAGitRepo,
    RefMissing,
    CommitMissing,
    BlobMissing,
    TreeMissing,
    ObjectMissing,
    OutOfMemory,
    NotImplemented,
    EndOfStream,
    PackCorrupt,
    PackRef,
    AmbiguousRef,
};

const Types = enum {
    commit,
    blob,
    tree,
};

pub const SHA = []const u8; // SUPERBAD, I'm sorry!

pub fn shaToHex(sha: []const u8, hex: []u8) void {
    std.debug.assert(sha.len == 20);
    std.debug.assert(hex.len == 40);
    const out = std.fmt.bufPrint(hex, "{}", .{hexLower(sha)}) catch unreachable;
    std.debug.assert(out.len == 40);
}

pub fn shaToBin(sha: []const u8, bin: []u8) void {
    std.debug.assert(sha.len == 40);
    std.debug.assert(bin.len == 20);
    for (0..20) |i| {
        bin[i] = std.fmt.parseInt(u8, sha[i * 2 .. (i + 1) * 2], 16) catch unreachable;
    }
}

const Object = struct {
    ctx: std.io.FixedBufferStream([]u8),
    kind: ?Kind = null,

    pub const Kind = enum {
        blob,
        tree,
        commit,
        ref,
    };

    pub const thing = union(Kind) {
        blob: Blob,
        tree: Tree,
        commit: Commit,
        ref: Ref,
    };

    const FBS = std.io.fixedBufferStream;

    pub fn init(data: []u8) Object {
        return Object{ .ctx = FBS(data) };
    }

    pub const ReadError = error{
        Unknown,
    };

    pub const Reader = std.io.Reader(*Object, ReadError, read);

    fn read(self: *Object, dest: []u8) ReadError!usize {
        return self.ctx.read(dest) catch return ReadError.Unknown;
    }

    pub fn reader(self: *Object) Object.Reader {
        return .{ .context = self };
    }

    pub fn reset(self: *Object) void {
        self.ctx.pos = 0;
    }

    pub fn raze(self: Object, a: Allocator) void {
        a.free(self.ctx.buffer);
    }
};

// TODO AnyReader
pub const Reader = Object.Reader;
pub const FBSReader = std.io.FixedBufferStream([]u8).Reader;
const FsReader = std.fs.File.Reader;

pub const Repo = struct {
    bare: bool,
    dir: std.fs.Dir,
    packs: []Pack,
    refs: []Ref,
    current: ?[]u8 = null,
    head: ?Ref = null,
    // Leaks, badly
    tags: ?[]Tag = null,

    repo_name: ?[]const u8 = null,

    /// on success d becomes owned by the returned Repo and will be closed on
    /// a call to raze
    pub fn init(d: std.fs.Dir) Error!Repo {
        var repo = initDefaults();
        repo.dir = d;
        if (d.openFile("./HEAD", .{})) |file| {
            file.close();
        } else |_| {
            if (d.openDir("./.git", .{})) |full| {
                if (full.openFile("./HEAD", .{})) |file| {
                    file.close();
                    repo.dir.close();
                    repo.dir = full;
                } else |_| return error.NotAGitRepo;
            } else |_| return error.NotAGitRepo;
        }

        return repo;
    }

    fn initDefaults() Repo {
        return Repo{
            .bare = false,
            .dir = undefined,
            .packs = &[0]Pack{},
            .refs = &[0]Ref{},
        };
    }

    /// Dir name must be relative (probably)
    pub fn createNew(a: Allocator, chdir: std.fs.Dir, dir_name: []const u8) !Repo {
        var agent = Agent{
            .alloc = a,
            .cwd = chdir,
        };

        a.free(try agent.initRepo(dir_name, .{}));
        var dir = try chdir.openDir(dir_name, .{});
        errdefer dir.close();
        return init(dir);
    }

    pub fn loadData(self: *Repo, a: Allocator) !void {
        if (self.packs.len == 0) try self.loadPacks(a);
        try self.loadRefs(a);
        _ = try self.HEAD(a);
    }

    const empty_sha = [_]u8{0} ** 20;

    fn loadFileObj(self: Repo, in_sha: SHA) !std.fs.File {
        var sha: [40]u8 = undefined;
        if (in_sha.len == 20) {
            shaToHex(in_sha, &sha);
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

    fn findBlobPack(self: Repo, a: Allocator, sha: SHA) !?[]u8 {
        for (self.packs) |pack| {
            if (pack.contains(sha)) |offset| {
                return try pack.loadObj(a, offset, self);
            }
        }
        return null;
    }

    fn findBlobPackPartial(self: Repo, a: Allocator, sha: SHA) !?[]u8 {
        for (self.packs) |pack| {
            if (try pack.containsPrefix(sha)) |offset| {
                return try pack.loadObj(a, offset, self);
            }
        }
        return null;
    }

    fn findBlobFile(self: Repo, a: Allocator, sha: SHA) !?[]u8 {
        if (self.loadFileObj(sha)) |fd| {
            defer fd.close();

            var decom = zlib.decompressor(fd.reader());
            var reader = decom.reader();
            return try reader.readAllAlloc(a, 0xffff);
        } else |_| {}
        return null;
    }

    fn findBlobPartial(self: Repo, a: Allocator, sha: SHA) ![]u8 {
        if (try self.findBlobPackPartial(a, sha)) |pack| return pack;
        //if (try self.findBlobFile(a, sha)) |file| return file;
        return error.ObjectMissing;
    }

    pub fn findBlob(self: Repo, a: Allocator, sha: SHA) ![]u8 {
        std.debug.assert(sha.len == 20);
        if (try self.findBlobPack(a, sha)) |pack| return pack;
        if (try self.findBlobFile(a, sha)) |file| return file;

        return error.ObjectMissing;
    }

    fn findObjPartial(self: Repo, a: Allocator, sha: SHA) !Object {
        std.debug.assert(sha.len % 2 == 0);
        std.debug.assert(sha.len <= 40);

        var shabuffer: [20]u8 = undefined;

        for (shabuffer[0 .. sha.len / 2], 0..sha.len / 2) |*s, i| {
            s.* = try std.fmt.parseInt(u8, sha[i * 2 ..][0..2], 16);
        }
        const shabin = shabuffer[0 .. sha.len / 2];
        if (try self.findBlobPackPartial(a, shabin)) |pack| return Object.init(pack);
        //if (try self.findBlobFile(a, shabin)) |file| return Object.init(file);
        return error.ObjectMissing;
    }

    /// TODO binary search lol
    pub fn findObj(self: Repo, a: Allocator, in_sha: SHA) !Object {
        var shabin: [20]u8 = in_sha[0..20].*;
        if (in_sha.len == 40) {
            for (&shabin, 0..) |*s, i| {
                s.* = try std.fmt.parseInt(u8, in_sha[i * 2 .. (i + 1) * 2], 16);
            }
        }

        if (try self.findBlobPack(a, &shabin)) |pack| return Object.init(pack);
        if (try self.findBlobFile(a, &shabin)) |file| return Object.init(file);
        return error.ObjectMissing;
    }

    pub fn loadPacks(self: *Repo, a: Allocator) !void {
        var dir = try self.dir.openDir("./objects/pack", .{ .iterate = true });
        defer dir.close();
        var itr = dir.iterate();
        var i: usize = 0;
        while (try itr.next()) |file| {
            if (!std.mem.eql(u8, file.name[file.name.len - 4 ..], ".idx")) continue;
            i += 1;
        }
        self.packs = try a.alloc(Pack, i);
        itr.reset();
        i = 0;
        while (try itr.next()) |file| {
            if (!std.mem.eql(u8, file.name[file.name.len - 4 ..], ".idx")) continue;

            self.packs[i] = try Pack.init(dir, try a.dupe(u8, file.name[0 .. file.name.len - 4]));
            i += 1;
        }
    }

    pub fn deref() Object {}

    pub fn loadRefs(self: *Repo, a: Allocator) !void {
        var list = std.ArrayList(Ref).init(a);
        var idir = try self.dir.openDir("refs/heads", .{ .iterate = true });
        defer idir.close();
        var itr = idir.iterate();
        while (try itr.next()) |file| {
            if (file.kind != .file) continue;
            var filename = [_]u8{0} ** 2048;
            var fname: []u8 = &filename;
            fname = try std.fmt.bufPrint(&filename, "./refs/heads/{s}", .{file.name});
            var f = try self.dir.openFile(fname, .{});
            defer f.close();
            var buf: [40]u8 = undefined;
            const read = try f.readAll(&buf);
            std.debug.assert(read == 40);
            try list.append(Ref{ .branch = .{
                .name = try a.dupe(u8, file.name),
                .sha = try a.dupe(u8, &buf),
                .repo = self,
            } });
        }
        if (self.dir.openFile("packed-refs", .{})) |file| {
            var buf: [2048]u8 = undefined;
            const size = try file.readAll(&buf);
            const b = buf[0..size];
            var p_itr = std.mem.split(u8, b, "\n");
            _ = p_itr.next();
            while (p_itr.next()) |line| {
                if (std.mem.indexOf(u8, line, "refs/heads")) |_| {
                    try list.append(Ref{ .branch = .{
                        .name = try a.dupe(u8, line[52..]),
                        .sha = try a.dupe(u8, line[0..40]),
                        .repo = self,
                    } });
                }
            }
        } else |_| {}
        self.refs = try list.toOwnedSlice();
    }

    /// TODO write the real function that goes here
    pub fn ref(self: Repo, str: []const u8) !SHA {
        for (self.refs) |r| {
            switch (r) {
                .sha => |s| return s,
                .tag => unreachable,
                .branch => |b| {
                    if (std.mem.eql(u8, b.name, str)) {
                        return b.sha;
                    }
                },
                .missing => return error.EmptyRef,
            }
        }
        return error.RefMissing;
    }

    pub fn resolve(self: Repo, r: Ref) !SHA {
        switch (r) {
            .tag => unreachable,
            .branch => |b| {
                return try self.ref(b.name);
            },
        }
    }

    /// TODO I don't want this to take an allocator :(
    /// Warning, has side effects!
    pub fn HEAD(self: *Repo, a: Allocator) !Ref {
        var f = try self.dir.openFile("HEAD", .{});
        defer f.close();
        var buff: [0xFF]u8 = undefined;

        const size = try f.read(&buff);
        const head = buff[0..size];

        if (std.mem.eql(u8, head[0..5], "ref: ")) {
            self.head = Ref{
                .branch = Branch{
                    .sha = self.ref(head[16 .. head.len - 1]) catch &[_]u8{0} ** 20,
                    .name = try a.dupe(u8, head[5 .. head.len - 1]),
                    .repo = self,
                },
            };
        } else if (head.len == 41 and head[40] == '\n') {
            self.head = Ref{
                .sha = try a.dupe(u8, head[0..40]), // We don't want that \n char
            };
        } else {
            std.debug.print("unexpected HEAD {s}\n", .{head});
            unreachable;
        }
        return self.head.?;
    }

    fn loadTag(self: *Repo, a: Allocator, lsha: SHA) !Tag {
        var sha: [20]u8 = lsha[0..20].*;
        if (lsha.len == 40) {
            for (&sha, 0..) |*s, i| {
                s.* = try std.fmt.parseInt(u8, lsha[i * 2 .. (i + 1) * 2], 16);
            }
        }
        const tag_blob = try self.findBlob(a, sha[0..]);
        return try Tag.fromSlice(lsha, tag_blob);
    }

    pub fn loadTags(self: *Repo, a: Allocator) !void {
        var rbuf: [2048]u8 = undefined;

        var tagdir = try self.dir.openDir("refs/tags", .{ .iterate = true });

        const rpath = try tagdir.realpath(".", &rbuf);
        std.debug.print("ready {s}\n", .{rpath});

        const pk_refs: ?[]const u8 = self.dir.readFileAlloc(a, "packed-refs", 0xffff) catch |err| pk: {
            std.debug.print("packed-refs {any}\n", .{err});
            break :pk null;
        };
        defer if (pk_refs) |pr| a.free(pr);

        defer tagdir.close();
        var itr = tagdir.iterate();
        var count: usize = if (pk_refs) |p| std.mem.count(u8, p, "refs/tags/") else 0;
        while (try itr.next()) |next| {
            std.debug.print("next {s} {any}\n", .{ next.name, next.kind });
            if (next.kind != .file) continue;
            count += 1;
        }
        if (count == 0) return;
        self.tags = try a.alloc(Tag, count);
        errdefer a.free(self.tags.?);
        errdefer self.tags = null;

        var index: usize = 0;
        if (pk_refs) |pkrefs| {
            var lines = splitScalar(u8, pkrefs, '\n');
            while (lines.next()) |line| {
                if (indexOf(u8, line, "refs/tags/") != null) {
                    self.tags.?[index] = try self.loadTag(a, line[0..40]);
                    index += 1;
                }
            }
        }

        itr.reset();
        while (try itr.next()) |next| {
            var fnbuf: [2048]u8 = undefined;
            if (next.kind != .file) continue;
            const fname = try bufPrint(&fnbuf, "refs/tags/{s}", .{next.name});
            var conbuf: [44]u8 = undefined;
            const contents = self.dir.readFile(fname, &conbuf) catch |err| {
                std.debug.print("unexpected tag format for {s}\n", .{fname});
                return err;
            };
            if (contents.len != 40) {
                std.debug.print("unexpected tag format for {s}\n", .{fname});
                return error.InvalidTagFound;
            }
            self.tags.?[index] = try self.loadTag(a, contents);
            index += 1;
        }
        if (index != self.tags.?.len) return error.UnexpectedError;
    }

    pub fn resolvePartial(_: *const Repo, _: SHA) !SHA {
        return error.NotImplemented;
    }

    pub fn commit(self: *const Repo, a: Allocator, request: SHA) !Commit {
        const target = request;
        var obj = if (request.len == 40)
            try self.findObj(a, target)
        else
            try self.findObjPartial(a, target);
        defer obj.raze(a);
        var cmt = try Commit.fromReader(a, target, obj.reader());
        cmt.repo = self;
        return cmt;
    }

    pub fn headCommit(self: *const Repo, a: Allocator) !Commit {
        const resolv = switch (self.head.?) {
            .sha => |s| s,
            .branch => |b| try self.ref(b.name["refs/heads/".len..]),
            .tag => return error.CommitMissing,
            .missing => return error.CommitMissing,
        };
        return try self.commit(a, resolv);
    }

    pub fn blob(self: Repo, a: Allocator, sha: SHA) !Object {
        var obj = try self.findObj(a, sha);

        if (std.mem.indexOf(u8, obj.ctx.buffer, "\x00")) |i| {
            return Object.init(obj.ctx.buffer[i + 1 ..]);
        }
        return obj;
    }

    pub fn description(self: Repo, a: Allocator) ![]u8 {
        if (self.dir.openFile("description", .{})) |*file| {
            defer file.close();
            return try file.readToEndAlloc(a, 0xFFFF);
        } else |_| {}
        return error.NoDescription;
    }

    pub fn raze(self: *Repo, a: Allocator) void {
        self.dir.close();
        for (self.packs) |pack| {
            pack.raze(a);
        }
        a.free(self.packs);
        for (self.refs) |r| switch (r) {
            .branch => |b| {
                a.free(b.name);
                a.free(b.sha);
            },
            else => unreachable,
        };
        a.free(self.refs);

        if (self.current) |c| a.free(c);
        if (self.head) |h| switch (h) {
            .branch => |b| a.free(b.name),
            else => {}, //a.free(h);
        };

        // TODO self.tags leaks, badly
    }

    // functions that might move or be removed...

    pub fn updatedAt(self: *Repo, a: Allocator) !i64 {
        var oldest: i64 = 0;
        for (self.refs) |r| {
            switch (r) {
                .branch => |br| {
                    const cmt = try br.toCommit(a);
                    defer cmt.raze();
                    if (cmt.committer.timestamp > oldest) oldest = cmt.committer.timestamp;
                },
                else => unreachable, // not implemented... sorry :/
            }
        }
        return oldest;
    }

    pub fn getAgent(self: *const Repo, a: Allocator) Agent {
        // FIXME if (!self.bare) provide_working_dir_to_git
        return .{
            .alloc = a,
            .repo = self,
            .cwd = self.dir,
        };
    }
};

pub const Branch = struct {
    name: []const u8,
    sha: SHA,
    repo: ?*const Repo = null,

    pub fn toCommit(self: Branch, a: Allocator) !Commit {
        const repo = self.repo orelse return error.NoConnectedRepo;
        var obj = try repo.findObj(a, self.sha);
        defer obj.raze(a);
        var cmt = try Commit.fromReader(a, self.sha, obj.reader());
        cmt.repo = repo;
        return cmt;
    }
};

pub const TagType = enum {
    commit,

    pub fn fromSlice(str: []const u8) ?TagType {
        inline for (std.meta.tags(TagType)) |t| {
            if (std.mem.eql(u8, @tagName(t), str)) return t;
        }
        return null;
    }
};

pub const Tag = struct {
    name: []const u8,
    sha: SHA,
    object: []const u8,
    type: TagType,
    tagger: Actor,
    message: []const u8,
    signature: ?[]const u8,
    //signature: ?Commit.GPGSig,

    pub fn fromSlice(sha: SHA, blob: []const u8) !Tag {
        var name: ?[]const u8 = null;
        var object: ?[]const u8 = null;
        var ttype: ?TagType = null;
        var actor: ?Actor = null;
        var itr = std.mem.splitScalar(u8, blob, '\n');
        while (itr.next()) |line| {
            if (startsWith(u8, line, "object ")) {
                object = line[7..];
            } else if (startsWith(u8, line, "type ")) {
                ttype = TagType.fromSlice(line[5..]);
            } else if (startsWith(u8, line, "tag ")) {
                name = line[4..];
            } else if (startsWith(u8, line, "tagger ")) {
                actor = Actor.make(line[7..]) catch return error.InvalidActor;
            } else if (line.len == 0) {
                break;
            }
        }

        var msg: []const u8 = blob[itr.index.?..];
        var sig: ?[]const u8 = null;
        const sigstart: usize = std.mem.indexOf(u8, msg, "-----BEGIN PGP SIGNATURE-----") orelse 0;
        msg = msg[0..sigstart];
        if (sigstart > 0) {
            sig = msg[0..];
        }

        return .{
            .name = name orelse return error.InvalidTagName,
            .sha = sha,
            .object = object orelse return error.InvalidReference,
            .type = ttype orelse return error.InvalidType,
            .tagger = actor orelse return error.InvalidActor,
            .message = msg,
            .signature = sig,
        };
    }

    /// LOL, don't use this
    fn fromReader(sha: SHA, reader: AnyReader) !Tag {
        var buffer: [0xFFFF]u8 = undefined;
        const len = try reader.readAll(&buffer);
        return try fromSlice(sha, buffer[0..len]);
    }

    test fromSlice {
        const blob =
            \\object 73751d1c0e9eaeaafbf38a938afd652d98ee9772
            \\type commit
            \\tag v0.7.3
            \\tagger Robin Linden <dev@robinlinden.eu> 1645477245 +0100
            \\
            \\Yet another bugfix release for 0.7.0, especially for Samsung phones.
            \\-----BEGIN PGP SIGNATURE-----
            \\
            \\iQIzBAABCAAdFiEEtwCP8SwHm/bm6hnRYBpgS35gV3YFAmIT/bYACgkQYBpgS35g
            \\V3bcww/+IQa+cSfRZkrGpTfHx+GzDVcW7R9FBxJ2vLicLB0yd2b3GgqBByEJCppo
            \\P0m2mb/rcFajcvJw9UmjUBMEljZSc1pW1/zioo9zRxt9g2zdVNxf1CoFwD/I9UbN
            \\oEM1KK+QyuqQ61Fbfz7kdpwOuaZ5UBe8/gH9TO+wURNNJE/PlsNCmengEtnERl+F
            \\J8FEJW0j1Offwdbw92WUvEVf6egH2N9NDqkhHM8Fy7+UwM4hJam7wclQODI19ZDI
            \\AKvH2vhLP+CVqvMiNlycTlDKqjka0pK4jOD4eu+2oeIzADH8kyMObhdFSdzscgEU
            \\ExAxwN2s5sD7Be1Z38gld9XRZ0f7JgZmdF+rkZqjF+tXcqxHIZtASWRD1cXLLwBc
            \\9b0/d626bZhKNYyIsvs1s0SHPBMNWCOGHV9oXi/Yncd7xoReGBFXrhhqub9ngmT4
            \\FksiZbyx3D6o22yyCU7roajLneL/JMKx+PmUxQxDdpqMyLZea3ETjFAKkAVnM0El
            \\GuKTlh/cxAdkz+WKKltVQNOfkc7rJvAnx81krggu354MDasg5EDjB7Nud/hQB+/s
            \\Dy/mr8QpGUoccHgUHTL7b7zmgIrTrq3NEkucMxKKoj9KRtt91w0OYPP4667gFKue
            \\+S4r2zj6UlFy7yODdWs8ijKwhSvMgJnUT6dnpGNCsJrc/F2O5ms=
            \\=t+5I
            \\-----END PGP SIGNATURE-----
            \\
        ;
        const t_msg = "Yet another bugfix release for 0.7.0, especially for Samsung phones.\n";
        const t = try fromSlice("c66fba80f3351a94432a662b1ecc55a21898f830", blob);
        try std.testing.expectEqualStrings("v0.7.3", t.name);
        try std.testing.expectEqualStrings("73751d1c0e9eaeaafbf38a938afd652d98ee9772", t.object);
        try std.testing.expectEqual(TagType.commit, t.type);
        try std.testing.expectEqualStrings("Robin Linden", t.tagger.name);
        try std.testing.expectEqualStrings(t_msg, t.message);
    }
};

pub const Ref = union(enum) {
    tag: Tag,
    branch: Branch,
    sha: SHA,
    missing: void,
};

/// TODO for commitish
/// direct
/// - [x] sha
/// - [ ] refname
/// - [ ] describe output (tag, etc)
/// - [ ] @
/// - [ ] ^
/// - [ ] +
/// - [ ] :
/// range
/// - [ ] ..
/// - [ ] ...
/// - [ ] ^
/// - [ ] ^-
/// - [ ] ^!
///
///
/// Warning only has support for sha currently
pub fn commitish(rev: []const u8) bool {
    if (rev.len < 4 or rev.len > 40) return false;

    for (rev) |c| switch (c) {
        'a'...'f' => continue,
        'A'...'F' => continue,
        '0'...'9' => continue,
        '.' => continue,
        else => return false,
    };
    return true;
}

pub fn commitishRepo(rev: []const u8, repo: Repo) bool {
    _ = rev;
    _ = repo;
    return false;
}

pub const ChangeSet = struct {
    name: []const u8,
    sha: []const u8,
    // Index into commit slice
    commit_title: []const u8,
    commit: []const u8,
    timestamp: i64,

    pub fn init(a: Allocator, name: []const u8, sha: []const u8, msg: []const u8, ts: i64) !ChangeSet {
        const commit = try a.dupe(u8, msg);
        return ChangeSet{
            .name = try a.dupe(u8, name),
            .sha = try a.dupe(u8, sha),
            .commit = commit,
            .commit_title = if (std.mem.indexOf(u8, commit, "\n\n")) |i| commit[0..i] else commit,
            .timestamp = ts,
        };
    }

    pub fn raze(self: ChangeSet, a: Allocator) void {
        a.free(self.name);
        a.free(self.sha);
        a.free(self.commit);
    }
};

test "hex tranlations" {
    var hexbuf: [40]u8 = undefined;
    var binbuf: [20]u8 = undefined;

    const one = "370303630b3fc631a0cb3942860fb6f77446e9c1";
    shaToBin(one, &binbuf);
    shaToHex(&binbuf, &hexbuf);
    try std.testing.expectEqualStrings(&binbuf, "\x37\x03\x03\x63\x0b\x3f\xc6\x31\xa0\xcb\x39\x42\x86\x0f\xb6\xf7\x74\x46\xe9\xc1");
    try std.testing.expectEqualStrings(&hexbuf, one);

    const two = "0000000000000000000000000000000000000000";
    shaToBin(two, &binbuf);
    shaToHex(&binbuf, &hexbuf);

    try std.testing.expectEqualStrings(&binbuf, "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    try std.testing.expectEqualStrings(&hexbuf, two);
}

test "read" {
    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./.git/objects/37/0303630b3fc631a0cb3942860fb6f77446e9c1", .{});
    var b: [1 << 16]u8 = undefined;

    var d = zlib.decompressor(file.reader());
    const count = try d.read(&b);
    //std.debug.print("{s}\n", .{b[0..count]});
    const commit = try Commit.make("370303630b3fc631a0cb3942860fb6f77446e9c1", b[0..count], null);
    //std.debug.print("{}\n", .{commit});
    try std.testing.expectEqualStrings("fcb6817b0efc397f1525ff7ee375e08703ed17a9", commit.tree);
    try std.testing.expectEqualStrings("370303630b3fc631a0cb3942860fb6f77446e9c1", commit.sha);
}

test "file" {
    const a = std.testing.allocator;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./.git/objects/37/0303630b3fc631a0cb3942860fb6f77446e9c1", .{});
    var d = zlib.decompressor(file.reader());
    const dz = try d.reader().readAllAlloc(a, 0xffff);
    var buffer = Object.init(dz);
    defer buffer.raze(a);
    const commit = try Commit.fromReader(a, "370303630b3fc631a0cb3942860fb6f77446e9c1", buffer.reader());
    defer commit.raze();
    //std.debug.print("{}\n", .{commit});
    try std.testing.expectEqualStrings("fcb6817b0efc397f1525ff7ee375e08703ed17a9", commit.tree);
    try std.testing.expectEqualStrings("370303630b3fc631a0cb3942860fb6f77446e9c1", commit.sha);
}

test "not gpg" {
    const null_sha = "0000000000000000000000000000000000000000";
    const blob_invalid_0 =
        \\tree 0000bb21f5276fd4f3611a890d12312312415434
        \\parent ffffff8bd96b1abaceaa3298374abo82f4239948
        \\author Some Dude <some@email.com> 1687200000 -0700
        \\committer Some Dude <some@email.com> 1687200000 -0700
        \\gpgsig -----BEGIN SSH SIGNATURE-----
        \\ U1NIU0lHQNTHOUAAADMAAAALc3NoLWVkMjU1MTkAAAAgRa/hEgY+LtKXmU4UizGarF0jm9
        \\ 1DXrxXaR8FmaEJOEUNTHADZ2l0AAAA45839473AINGEUTIAAABTAAAAC3NzaC1lZETN&/3
        \\ BBEAQFzdXKXCV2F5ZXWUo46L5MENOTTEOU98367258dsteuhi876234OEU876+OEU876IO
        \\ 12238aaOEIUvwap+NcCEOEUu9vwQ=
        \\ -----END SSH SIGNATURE-----
        \\
        \\commit message
    ;
    const commit = try Commit.make(null_sha, blob_invalid_0, null);
    try std.testing.expect(commit.sha.ptr == null_sha.ptr);
}

test "toParent" {
    const a = std.testing.allocator;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd);
    defer repo.raze(a);
    try repo.loadData(a);
    var commit = try repo.headCommit(a);

    var count: usize = 0;
    while (true) {
        count += 1;
        if (commit.parent[0]) |_| {
            const parent = try commit.toParent(a, 0);
            commit.raze();
            commit = parent;
        } else break;
    }
    commit.raze();
    try std.testing.expect(count >= 31); // LOL SORRY!
}

test "tree" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./.git/objects/37/0303630b3fc631a0cb3942860fb6f77446e9c1", .{});
    var _zlib = zlib.decompressor(file.reader());
    var reader = _zlib.reader();
    const data = try reader.readAllAlloc(a, 0xffff);
    defer a.free(data);
    var buffer = Object.init(data);
    const commit = try Commit.fromReader(a, "370303630b3fc631a0cb3942860fb6f77446e9c1", buffer.reader());
    defer commit.raze();
    //std.debug.print("tree {s}\n", .{commit.sha});
}

test "tree decom" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./.git/objects/5e/dabf724389ef87fa5a5ddb2ebe6dbd888885ae", .{});
    var b: [1 << 16]u8 = undefined;

    var d = zlib.decompressor(file.reader());
    const count = try d.read(&b);
    const buf = try a.dupe(u8, b[0..count]);
    var tree = try Tree.make(a, "5edabf724389ef87fa5a5ddb2ebe6dbd888885ae", buf);
    defer tree.raze(a);
    for (tree.objects) |obj| {
        if (false) std.debug.print("{s} {s} {s}\n", .{ obj.mode, obj.hash, obj.name });
    }
    if (false) std.debug.print("{}\n", .{tree});
}

test "tree child" {
    var a = std.testing.allocator;
    const child = try std.ChildProcess.run(.{
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
    const a = std.testing.allocator;
    var cwd = std.fs.cwd();
    const dir = try cwd.openDir("repos/hastur", .{});
    var repo = try Repo.init(dir);
    defer repo.raze(a);

    try repo.loadPacks(a);
    var lol: []u8 = "";

    for (repo.packs, 0..) |pack, pi| {
        for (0..@byteSwap(pack.idx_header.fanout[255])) |oi| {
            const hexy = pack.objnames[oi * 20 .. oi * 20 + 20];
            if (hexy[0] != 0xd2) continue;
            if (false) std.debug.print("{} {} -> {}\n", .{ pi, oi, hexLower(hexy) });
            if (hexy[1] == 0xb4 and hexy[2] == 0xd1) {
                if (false) std.debug.print("{s} -> {}\n", .{ pack.name, pack.offsets[oi] });
                lol = hexy;
            }
        }
    }
    var obj = try repo.findObj(a, lol);
    defer obj.raze(a);
    const commit = try Commit.fromReader(a, lol, obj.reader());
    defer commit.raze();
    if (false) std.debug.print("{}\n", .{commit});
}

test "pack contains" {
    const a = std.testing.allocator;
    var cwd = std.fs.cwd();
    const dir = try cwd.openDir("repos/srctree", .{});
    var repo = try Repo.init(dir);
    try repo.loadPacks(a);
    defer repo.raze(a);

    const sha = "7d4786ded56e1ee6cfe72c7986218e234961d03c";
    var shabin: [20]u8 = undefined;
    for (&shabin, 0..) |*s, i| {
        s.* = try std.fmt.parseInt(u8, sha[i * 2 ..][0..2], 16);
    }

    var found: bool = false;
    for (repo.packs) |pack| {
        found = pack.contains(shabin[0..20]) != null;
        if (found) break;
    }
    try std.testing.expect(found);

    found = false;
    for (repo.packs) |pack| {
        found = try pack.containsPrefix(shabin[0..10]) != null;
        if (found) break;
    }
    try std.testing.expect(found);

    const err = repo.packs[0].containsPrefix(shabin[0..1]);
    try std.testing.expectError(error.AmbiguousRef, err);

    //var long_obj = try repo.findObj(a, lol);
}

test "hopefully a delta" {
    const a = std.testing.allocator;
    var cwd = std.fs.cwd();
    const dir = try cwd.openDir("repos/hastur", .{});
    var repo = try Repo.init(dir);
    defer repo.raze(a);

    try repo.loadData(a);

    var head = try repo.headCommit(a);
    defer head.raze();
    //std.debug.print("{}\n", .{head});

    var obj = try repo.findObj(a, head.tree);
    defer obj.raze(a);
    const tree = try Tree.fromReader(a, head.tree, obj.reader());
    tree.raze(a);
    if (false) std.debug.print("{}\n", .{tree});
}

test "commit to tree" {
    const a = std.testing.allocator;
    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd);
    defer repo.raze(a);

    try repo.loadData(a);

    const cmt = try repo.headCommit(a);
    defer cmt.raze();
    const tree = try cmt.mkTree(a);
    defer tree.raze(a);
    if (false) std.debug.print("tree {}\n", .{tree});
    if (false) for (tree.objects) |obj| std.debug.print("    {}\n", .{obj});
}

test "blob to commit" {
    var a = std.testing.allocator;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd);
    defer repo.raze(a);

    try repo.loadData(a);

    const cmtt = try repo.headCommit(a);
    defer cmtt.raze();

    const tree = try cmtt.mkTree(a);
    defer tree.raze(a);

    var timer = try std.time.Timer.start();
    var lap = timer.lap();
    const found = try tree.changedSet(a, &repo);
    if (false) std.debug.print("found {any}\n", .{found});
    for (found) |f| f.raze(a);
    a.free(found);
    lap = timer.lap();
    if (false) std.debug.print("timer {}\n", .{lap});
}

test "mk sub tree" {
    const a = std.testing.allocator;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd);
    defer repo.raze(a);

    try repo.loadData(a);

    const cmtt = try repo.headCommit(a);
    defer cmtt.raze();

    const tree = try cmtt.mkTree(a);
    defer tree.raze(a);

    var blob: Blob = blb: for (tree.objects) |obj| {
        if (std.mem.eql(u8, obj.name, "src")) break :blb obj;
    } else return error.ExpectedBlobMissing;
    var subtree = try blob.toTree(a, repo);
    if (false) std.debug.print("{any}\n", .{subtree});
    for (subtree.objects) |obj| {
        if (false) std.debug.print("{any}\n", .{obj});
    }

    subtree.raze(a);
}

test "commit mk sub tree" {
    var a = std.testing.allocator;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd);
    defer repo.raze(a);

    try repo.loadData(a);

    const cmtt = try repo.headCommit(a);
    defer cmtt.raze();

    const tree = try cmtt.mkTree(a);
    defer tree.raze(a);

    var blob: Blob = blb: for (tree.objects) |obj| {
        if (std.mem.eql(u8, obj.name, "src")) break :blb obj;
    } else return error.ExpectedBlobMissing;
    var subtree = try blob.toTree(a, repo);
    if (false) std.debug.print("{any}\n", .{subtree});
    for (subtree.objects) |obj| {
        if (false) std.debug.print("{any}\n", .{obj});
    }
    defer subtree.raze(a);

    const csubtree = try cmtt.mkSubTree(a, "src");
    if (false) std.debug.print("{any}\n", .{csubtree});
    csubtree.raze(a);

    const csubtree2 = try cmtt.mkSubTree(a, "src/endpoints");
    if (false) std.debug.print("{any}\n", .{csubtree2});
    if (false) for (csubtree2.objects) |obj|
        std.debug.print("{any}\n", .{obj});
    defer csubtree2.raze(a);

    const changed = try csubtree2.changedSet(a, &repo);
    for (csubtree2.objects, changed) |o, c| {
        if (false) std.debug.print("{s} {s}\n", .{ o.name, c.sha });
        c.raze(a);
    }
    a.free(changed);
}
test "considering optimizing blob to commit" {
    //var a = std.testing.allocator;
    //var cwd = std.fs.cwd();

    //var dir = try cwd.openDir("repos/zig", .{});
    //var repo = try Repo.init(dir);

    ////var repo = try Repo.init(cwd);
    //var timer = try std.time.Timer.start();
    //defer repo.raze(a);

    //try repo.loadPacks(a);

    //const cmtt = try repo.headCommit(a);
    //defer cmtt.raze();

    //const tree = try cmtt.mkTree(a);
    //defer tree.raze(a);
    //var search_list: []?Blob = try a.alloc(?Blob, tree.objects.len);
    //for (tree.objects, search_list) |src, *dst| {
    //    dst.* = src;
    //}
    //defer a.free(search_list);

    //var par = try repo.headCommit(a);
    //var ptree = try par.mkTree(a);

    //var old = par;
    //var oldtree = ptree;
    //var found: usize = 0;
    //var lap = timer.lap();
    //while (found < search_list.len) {
    //    old = par;
    //    oldtree = ptree;
    //    par = try par.toParent(a, 0);
    //    ptree = try par.mkTree(a);
    //    for (search_list) |*search_ish| {
    //        const search = search_ish.* orelse continue;
    //        var line = search.name;
    //        line.len += 21;
    //        line = line[line.len - 20 .. line.len];
    //        if (std.mem.indexOf(u8, ptree.blob, line)) |_| {} else {
    //            search_ish.* = null;
    //            found += 1;
    //            if (false) std.debug.print("    commit for {s} is {s} ({} rem)\n", .{
    //                search.name,
    //                old.sha,
    //                search_list.len - found,
    //            });
    //            continue;
    //        }
    //    }
    //    old.raze();
    //    oldtree.raze(a);
    //}
    //lap = timer.lap();
    //std.debug.print("timer {}\n", .{lap});

    //par.raze(a);
    //ptree.raze(a);
    //par = try repo.headCommit(a);
    //ptree = try par.mkTree(a);

    //var set = std.BufSet.init(a);
    //defer set.deinit();

    //while (set.count() < tree.objects.len) {
    //    old = par;
    //    oldtree = ptree;
    //    par = try par.toParent(a, 0);
    //    ptree = try par.mkTree(a);
    //    if (tree.objects.len != ptree.objects.len) {
    //        objl: for (tree.objects) |obj| {
    //            if (set.contains(&obj.hash)) continue;
    //            for (ptree.objects) |pobj| {
    //                if (std.mem.eql(u8, pobj.name, obj.name)) {
    //                    if (!std.mem.eql(u8, &pobj.hash, &obj.hash)) {
    //                        try set.insert(&obj.hash);
    //                        std.debug.print("    commit for {s} is {s}\n", .{ obj.name, old.sha });
    //                        continue :objl;
    //                    }
    //                }
    //            } else {
    //                try set.insert(&obj.hash);
    //                std.debug.print("    commit added {}\n", .{obj});
    //                continue :objl;
    //            }
    //        }
    //    } else {
    //        for (tree.objects, ptree.objects) |obj, pobj| {
    //            if (set.contains(&obj.hash)) continue;
    //            if (!std.mem.eql(u8, &pobj.hash, &obj.hash)) {
    //                if (std.mem.eql(u8, pobj.name, obj.name)) {
    //                    try set.insert(&obj.hash);
    //                    std.debug.print("    commit for {s} is {s}\n", .{ obj.name, old.sha });
    //                    continue;
    //                } else std.debug.print("    error on commit for {}\n", .{obj});
    //            }
    //        }
    //    }
    //    old.raze();
    //    oldtree.raze(a);
    //}
    //lap = timer.lap();
    //std.debug.print("timer {}\n", .{lap});

    //par.raze(a);
    //ptree.raze(a);
}

test "ref delta" {
    var a = std.testing.allocator;
    var cwd = std.fs.cwd();
    const dir = cwd.openDir("repos/hastur", .{}) catch return error.skip;

    var repo = try Repo.init(dir);
    defer repo.raze(a);

    try repo.loadData(a);

    const cmtt = try repo.headCommit(a);
    defer cmtt.raze();

    const tree = try cmtt.mkTree(a);
    defer tree.raze(a);

    var timer = try std.time.Timer.start();
    var lap = timer.lap();
    const found = try tree.changedSet(a, &repo);
    if (false) std.debug.print("found {any}\n", .{found});
    for (found) |f| f.raze(a);
    a.free(found);
    lap = timer.lap();
    if (false) std.debug.print("timer {}\n", .{lap});
}

test "forkRemote" {
    const a = std.testing.allocator;
    var tdir = std.testing.tmpDir(.{});
    defer tdir.cleanup();

    const agent = Agent{
        .alloc = a,
        .cwd = tdir.dir,
    };
    _ = agent;
    // TODO don't get banned from github
    //var result = try act.forkRemote("https://github.com/grayhatter/srctree", "srctree_tmp");
    //std.debug.print("{s}\n", .{result});
}

test "new repo" {
    const a = std.testing.allocator;
    var tdir = std.testing.tmpDir(.{});
    defer tdir.cleanup();

    var new_repo = try Repo.createNew(a, tdir.dir, "new_repo");
    _ = try tdir.dir.openDir("new_repo", .{});
    try new_repo.loadData(a);
    defer new_repo.raze(a);
}

test "updated at" {
    const a = std.testing.allocator;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd);
    defer repo.raze(a);

    try repo.loadData(a);
    const oldest = try repo.updatedAt(a);
    _ = oldest;
    //std.debug.print("{}\n", .{oldest});
}
