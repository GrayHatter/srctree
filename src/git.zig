const Ini = @import("ini.zig");

pub const Actor = @import("git/actor.zig");
pub const Agent = @import("git/agent.zig");
pub const Blob = @import("git/blob.zig");
pub const Commit = @import("git/commit.zig");
pub const Pack = @import("git/pack.zig");
pub const Tree = @import("git/tree.zig");
pub const Remote = @import("git/remote.zig");
pub const ChangeSet = @import("git/changeset.zig");

pub const Error = error{
    ReadError,
    NotAGitRepo,
    RefMissing,
    CommitMissing,
    InvalidCommit,
    BlobMissing,
    TreeMissing,
    InvalidTree,
    ObjectMissing,
    IncompleteObject,
    OutOfMemory,
    NoSpaceLeft,
    NotImplemented,
    EndOfStream,
    PackCorrupt,
    PackRef,
    AmbiguousRef,
};

pub const SHA = struct {
    pub const Bin = [20]u8;
    pub const Hex = [40]u8;
    bin: Bin,
    hex: Hex,
    partial: bool = false,
    len: usize = 0,
    binlen: usize = 0,

    pub fn init(sha: []const u8) SHA {
        if (sha.len == 20) {
            return .{
                .bin = sha[0..20].*,
                .hex = toHex(sha[0..20].*),
            };
        } else if (sha.len == 40) {
            return .{
                .bin = toBin(sha[0..40].*),
                .hex = sha[0..40].*,
            };
        } else unreachable;
    }

    /// TODO return error, and validate it's actually hex
    pub fn initPartial(sha: []const u8) SHA {
        var buf: [40]u8 = ("0" ** 40).*;
        for (buf[0..sha.len], sha[0..]) |*dst, src| dst.* = src;
        return .{
            .bin = toBin(buf[0..40].*),
            .hex = buf[0..].*,
            .partial = true,
            .len = sha.len,
            .binlen = sha.len / 2,
        };
    }

    pub fn toHex(sha: Bin) Hex {
        var hex: Hex = undefined;
        _ = bufPrint(&hex, "{}", .{hexLower(sha[0..])}) catch unreachable;
        return hex;
    }

    pub fn toBin(sha: Hex) Bin {
        var bin: Bin = undefined;
        for (0..20) |i| {
            bin[i] = parseInt(u8, sha[i * 2 .. (i + 1) * 2], 16) catch unreachable;
        }
        return bin;
    }

    pub fn eql(self: SHA, peer: SHA) bool {
        if (self.partial == true) @panic("not implemented");
        if (self.partial != peer.partial) return false;
        return std.mem.eql(u8, self.bin[0..20], peer.bin[0..20]);
    }

    pub fn eqlIsh(self: SHA, peer: SHA) bool {
        if (self.partial == true) @panic("not implemented");
        if (peer.partial != true) return self.eql(peer);
        return std.mem.eql(u8, self.bin[0..peer.binlen], peer.bin[0..peer.binlen]);
    }
};

pub const Object = struct {
    pub const Kind = enum {
        blob,
        tree,
        commit,
        tag,
    };
    kind: Kind,
    memory: []u8,
    header: []u8,
    body: []u8,
};

pub const Repo = struct {
    alloc: ?Allocator = null,
    bare: bool,
    dir: std.fs.Dir,
    packs: []Pack,
    refs: []Ref,
    current: ?[]u8 = null,
    head: ?Ref = null,
    // Leaks, badly
    tags: ?[]Tag = null,
    branches: ?[]Branch = null,
    remotes: ?[]Remote = null,

    repo_name: ?[]const u8 = null,

    /// on success d becomes owned by the returned Repo and will be closed on
    /// a call to raze
    pub fn init(d: std.fs.Dir) Error!Repo {
        var repo = initDefaults();
        repo.dir = d;
        if (d.openFile("./HEAD", .{})) |file| {
            file.close();
            repo.bare = true;
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
        if (self.alloc != null) unreachable;
        self.alloc = a;

        try self.loadPacks();
        try self.loadRefs();
        try self.loadTags();
        try self.loadBranches();
        try self.loadRemotes();
        _ = try self.HEAD(a);
    }

    fn loadRemotes(self: *Repo) !void {
        const a = self.alloc orelse unreachable;
        var list = std.ArrayList(Remote).init(a);
        errdefer list.clearAndFree();
        const config_data = try self.dir.readFileAlloc(a, "config", 0xffff);
        const cfg = try Ini.Config(void).initOwned(a, config_data);
        defer cfg.raze(a);
        for (0..cfg.ns.len) |i| {
            const ns = cfg.filter("remote", i) orelse break;
            try list.append(.{
                .name = try a.dupe(u8, std.mem.trim(u8, ns.name[6..], "' \t\n\"")),
                .url = if (ns.get("url")) |url| try a.dupe(u8, url) else null,
                .fetch = if (ns.get("fetch")) |fetch| try a.dupe(u8, fetch) else null,
            });
        }

        self.remotes = try list.toOwnedSlice();
    }

    pub fn findRemote(self: Repo, name: []const u8) !?*const Remote {
        const remotes = self.remotes orelse unreachable;
        for (remotes) |*remote| {
            if (eql(u8, remote.name, name)) {
                return remote;
            }
        }
        return null;
    }

    fn loadFile(self: Repo, a: Allocator, sha: SHA) !Object {
        var fb = [_]u8{0} ** 2048;
        const grouped = try bufPrint(&fb, "./objects/{s}/{s}", .{ sha.hex[0..2], sha.hex[2..] });
        const compressed: []u8 = self.dir.readFileAlloc(a, grouped, 0xffffff) catch |err| switch (err) {
            error.FileNotFound => data: {
                const exact = try bufPrint(&fb, "./objects/{s}", .{sha.hex[0..]});
                break :data self.dir.readFileAlloc(a, exact, 0xffffff) catch |err2| switch (err2) {
                    error.FileNotFound => {
                        std.debug.print("unable to find commit '{s}'\n", .{sha.hex[0..]});
                        return error.ObjectMissing;
                    },
                    else => return err2,
                };
            },
            else => return err,
        };
        defer a.free(compressed);
        var fbs = std.io.fixedBufferStream(compressed);
        const fbsr = fbs.reader();
        var decom = zlib.decompressor(fbsr);
        const decomr = decom.reader();
        const data = try decomr.readAllAlloc(a, 0xffffff);
        errdefer a.free(data);
        if (indexOf(u8, data, "\x00")) |i| {
            return .{
                .memory = data,
                .header = data[0..i],
                .body = data[i + 1 ..],
                .kind = if (startsWith(u8, data, "blob "))
                    .blob
                else if (startsWith(u8, data, "tree "))
                    .tree
                else if (startsWith(u8, data, "commit "))
                    .commit
                else if (startsWith(u8, data, "tag "))
                    .tag
                else
                    return error.InvalidObject,
            };
        } else return error.InvalidObject;
    }

    fn loadPacked(self: Repo, a: Allocator, sha: SHA) !?Object {
        for (self.packs) |pack| {
            if (pack.contains(sha)) |offset| {
                return try pack.resolveObject(a, offset, &self);
            }
        }
        return null;
    }

    fn expandPartial(self: Repo, sha: SHA) !?SHA {
        std.debug.assert(sha.partial == true);
        for (self.packs) |pack| {
            if (try pack.containsPrefix(sha.bin[0..sha.binlen])) |_| {
                return try pack.expandPrefix(sha.bin[0..sha.binlen]);
            }
        }
        return null;
    }

    fn loadPackedPartial(self: Repo, a: Allocator, sha: SHA) !?Object {
        std.debug.assert(sha.partial == true);
        for (self.packs) |pack| {
            if (try pack.containsPrefix(sha.bin[0..sha.binlen])) |offset| {
                return try pack.resolveObject(a, offset, &self);
            }
        }
        return null;
    }

    fn loadPartial(self: Repo, a: Allocator, sha: SHA) !Pack.PackedObject {
        if (try self.loadPackedPartial(a, sha)) |pack| return pack;
        return error.ObjectMissing;
    }

    fn loadObjPartial(self: Repo, a: Allocator, sha: SHA) !?Object {
        std.debug.assert(sha.partial);

        if (try self.loadPackedPartial(a, sha)) |pack| return pack;
        return null;
    }

    pub fn loadObjectOrDelta(self: Repo, a: Allocator, sha: SHA) !union(enum) {
        pack: Pack.PackedObject,
        file: Object,
    } {
        for (self.packs) |pack| {
            if (pack.contains(sha)) |offset| {
                return .{ .pack = try pack.loadData(a, offset, &self) };
            }
        }
        return .{ .file = try self.loadFile(a, sha) };
    }

    /// TODO binary search lol
    pub fn loadObject(self: Repo, a: Allocator, sha: SHA) !Object {
        std.debug.assert(sha.partial == false);
        if (try self.loadPacked(a, sha)) |pack| return pack;
        return try self.loadFile(a, sha);
    }

    pub fn loadBlob(self: Repo, a: Allocator, sha: SHA) !Blob {
        const obj = try self.loadObject(a, sha);
        switch (obj.kind) {
            .blob => {
                return Blob{
                    .memory = obj.memory,
                    .sha = sha,
                    .mode = undefined,
                    .name = undefined,
                    .data = obj.body,
                };
            },
            .tree, .commit, .tag => unreachable,
        }
    }
    pub fn loadTree(self: Repo, a: Allocator, sha: SHA) !Tree {
        const obj = try self.loadObject(a, sha);
        switch (obj.kind) {
            .tree => return try Tree.initOwned(sha, a, obj),
            .blob, .commit, .tag => unreachable,
        }
    }
    pub fn loadCommit(self: Repo, a: Allocator, sha: SHA) !Commit {
        const obj = try self.loadObject(a, sha);
        switch (obj.kind) {
            .blob, .tree, .tag => unreachable,
            .commit => return try Commit.initOwned(sha, a, obj),
        }
    }

    fn loadTag(self: *Repo, a: Allocator, sha: SHA) !Tag {
        const obj = try self.loadObject(a, sha);
        switch (obj.kind) {
            .blob, .tree => unreachable,
            .commit => return try Tag.lightTag(sha, obj.body),
            .tag => return try Tag.fromSlice(sha, obj.body),
        }
    }

    pub fn loadPacks(self: *Repo) !void {
        const a = self.alloc orelse unreachable;
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

            self.packs[i] = try Pack.init(dir, file.name[0 .. file.name.len - 4]);
            i += 1;
        }
    }

    pub fn loadRefs(self: *Repo) !void {
        const a = self.alloc orelse unreachable;
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
                .alloc = a,
                .name = try a.dupe(u8, file.name),
                .sha = SHA.init(&buf),
                .repo = self,
            } });
        }
        if (self.dir.openFile("packed-refs", .{})) |file| {
            var buf: [2048]u8 = undefined;
            const size = try file.readAll(&buf);
            const b = buf[0..size];
            var p_itr = splitScalar(u8, b, '\n');
            _ = p_itr.next();
            while (p_itr.next()) |line| {
                if (std.mem.indexOf(u8, line, "refs/heads")) |_| {
                    try list.append(Ref{ .branch = .{
                        .alloc = a,
                        .name = try a.dupe(u8, line[52..]),
                        .sha = SHA.init(line[0..40]),
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
                    .alloc = a,
                    .sha = self.ref(head[16 .. head.len - 1]) catch SHA.init(&[_]u8{0} ** 20),
                    .name = try a.dupe(u8, head[5 .. head.len - 1]),
                    .repo = self,
                },
            };
        } else if (head.len == 41 and head[40] == '\n') {
            self.head = Ref{
                .sha = SHA.init(head[0..40]), // We don't want that \n char
            };
        } else {
            std.debug.print("unexpected HEAD {s}\n", .{head});
            unreachable;
        }
        return self.head.?;
    }

    fn loadTags(self: *Repo) !void {
        const a = self.alloc orelse unreachable;
        var tagdir = try self.dir.openDir("refs/tags", .{ .iterate = true });
        const pk_refs: ?[]const u8 = self.dir.readFileAlloc(a, "packed-refs", 0xffff) catch |err| switch (err) {
            error.FileNotFound => null,
            else => {
                std.debug.print("packed-refs {any}\n", .{err});
                unreachable;
            },
        };
        defer if (pk_refs) |pr| a.free(pr);

        defer tagdir.close();
        var itr = tagdir.iterate();
        var count: usize = if (pk_refs) |p| std.mem.count(u8, p, "refs/tags/") else 0;
        while (try itr.next()) |next| {
            if (next.kind != .file) continue;
            count += 1;
        }
        if (count == 0) return;
        self.tags = try a.alloc(Tag, count);
        errdefer self.tags = null;
        errdefer a.free(self.tags.?);

        var index: usize = 0;
        if (pk_refs) |pkrefs| {
            var lines = splitScalar(u8, pkrefs, '\n');
            while (lines.next()) |line| {
                if (indexOf(u8, line, "refs/tags/") != null) {
                    self.tags.?[index] = try self.loadTag(a, SHA.init(line[0..40]));
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
            if (contents.len != 41) {
                std.debug.print("unexpected tag format for {s}\n", .{fname});
                return error.InvalidTagFound;
            }
            self.tags.?[index] = try self.loadTag(a, SHA.init(contents[0..40]));
            index += 1;
        }
        if (index != self.tags.?.len) return error.UnexpectedError;
    }

    fn loadBranches(self: *Repo) !void {
        const a = self.alloc orelse unreachable;

        var branchdir = try self.dir.openDir("refs/heads", .{ .iterate = true });
        defer branchdir.close();
        var list = std.ArrayList(Branch).init(a);
        var itr = branchdir.iterate();
        while (try itr.next()) |file| {
            if (file.kind != .file) continue;
            var fnbuf: [2048]u8 = undefined;
            const fname = try bufPrint(&fnbuf, "refs/heads/{s}", .{file.name});
            var shabuf: [41]u8 = undefined;
            _ = try self.dir.readFile(fname, &shabuf);
            try list.append(.{
                .alloc = a,
                .name = try a.dupe(u8, file.name),
                .sha = SHA.init(shabuf[0..40]),
                .repo = self,
            });
        }
        self.branches = try list.toOwnedSlice();
    }

    pub fn resolvePartial(_: *const Repo, _: SHA) !SHA {
        return error.NotImplemented;
    }

    pub fn commit(self: *const Repo, a: Allocator, sha: SHA) !Commit {
        var obj: ?Object = null;
        var fullsha: SHA = sha;

        if (sha.partial) {
            obj = try self.loadObjPartial(a, sha);
            fullsha = try self.expandPartial(sha) orelse sha;
        } else {
            obj = try self.loadObject(a, sha);
        }
        if (obj == null) return error.CommitMissing;
        return try Commit.initOwned(fullsha, a, obj.?);
    }

    pub fn headCommit(self: *const Repo, a: Allocator) !Commit {
        const resolv: SHA = switch (self.head.?) {
            .sha => |s| s,
            .branch => |b| try self.ref(b.name["refs/heads/".len..]),
            .tag => return error.CommitMissing,
            .missing => return error.CommitMissing,
        };
        return try self.commit(a, resolv);
    }

    pub fn blob(self: Repo, a: Allocator, sha: SHA) !Blob {
        return try self.loadBlob(a, sha);
    }

    pub fn description(self: Repo, a: Allocator) ![]u8 {
        if (self.dir.openFile("description", .{})) |*file| {
            defer file.close();
            return try file.readToEndAlloc(a, 0xFFFF);
        } else |_| {}
        return error.NoDescription;
    }

    pub fn raze(self: *Repo) void {
        self.dir.close();
        if (self.alloc) |a| {
            for (self.packs) |pack| {
                pack.raze();
            }
            a.free(self.packs);
            for (self.refs) |r| switch (r) {
                .branch => |b| {
                    a.free(b.name);
                },
                else => unreachable,
            };
            a.free(self.refs);

            if (self.current) |c| a.free(c);
            if (self.head) |h| switch (h) {
                .branch => |b| a.free(b.name),
                else => {}, //a.free(h);
            };
            if (self.branches) |branches| {
                for (branches) |branch| branch.raze();
                a.free(branches);
            }
            if (self.remotes) |remotes| {
                for (remotes) |remote| remote.raze(a);
                a.free(remotes);
            }
        }
        // TODO self.tags leaks, badly
    }

    // functions that might move or be removed...

    pub fn updatedAt(self: *const Repo, a: Allocator) !i64 {
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
    alloc: Allocator,
    name: []const u8,
    sha: SHA,
    repo: *const Repo,

    pub fn toCommit(self: Branch, a: Allocator) !Commit {
        const obj = try self.repo.loadObject(a, self.sha);
        return Commit.initOwned(self.sha, a, obj);
    }

    pub fn raze(self: Branch) void {
        self.alloc.free(self.name);
    }
};

pub const TagType = enum {
    commit,
    lightweight,

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

    pub fn fromSlice(sha: SHA, bblob: []const u8) !Tag {
        // sometimes, the slice will have a preamble
        var blob = bblob;
        if (indexOf(u8, bblob[0..20], "\x00")) |i| {
            std.debug.assert(startsWith(u8, bblob, "tag "));
            blob = bblob[i + 1 ..];
        }
        //std.debug.print("tag\n{s}\n{s}\n", .{ sha, bblob });
        if (startsWith(u8, blob, "tree ")) return try lightTag(sha, blob);
        return try fullTag(sha, blob);
    }

    /// I don't like this implementation, but I can't be arsed... good luck
    /// future me!
    /// Dear past me... fuck you! dear future me... HA same!
    fn lightTag(sha: SHA, blob: []const u8) !Tag {
        var actor: ?Actor = null;
        if (indexOf(u8, blob, "committer ")) |i| {
            var act = blob[i + 10 ..];
            if (indexOf(u8, act, "\n")) |end| act = act[0..end];
            actor = Actor.make(act) catch return error.InvalidActor;
        } else return error.InvalidTag;

        return .{
            .name = "[lightweight tag]",
            .sha = sha,
            .object = sha.hex[0..],
            .type = .lightweight,
            .tagger = actor orelse unreachable,
            .message = "",
            .signature = null,
        };
    }

    fn fullTag(sha: SHA, blob: []const u8) !Tag {
        var name: ?[]const u8 = null;
        var object: ?[]const u8 = null;
        var ttype: ?TagType = null;
        var actor: ?Actor = null;
        var itr = splitScalar(u8, blob, '\n');
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
        const t = try fromSlice(SHA.init("c66fba80f3351a94432a662b1ecc55a21898f830"), blob);
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

test "hex tranlations" {
    const one = "370303630b3fc631a0cb3942860fb6f77446e9c1";
    var binbuf: [20]u8 = SHA.toBin(one.*);
    var hexbuf: [40]u8 = SHA.toHex(binbuf);

    try std.testing.expectEqualStrings(&binbuf, "\x37\x03\x03\x63\x0b\x3f\xc6\x31\xa0\xcb\x39\x42\x86\x0f\xb6\xf7\x74\x46\xe9\xc1");
    try std.testing.expectEqualStrings(&hexbuf, one);

    const two = "0000000000000000000000000000000000000000";
    binbuf = SHA.toBin(two.*);
    hexbuf = SHA.toHex(binbuf);

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
    const commit = try Commit.init(SHA.init("370303630b3fc631a0cb3942860fb6f77446e9c1"), b[11 .. count - 11]);
    //std.debug.print("{}\n", .{commit});
    try std.testing.expectEqualStrings("fcb6817b0efc397f1525ff7ee375e08703ed17a9", commit.tree.hex[0..]);
    try std.testing.expectEqualStrings("370303630b3fc631a0cb3942860fb6f77446e9c1", commit.sha.hex[0..]);
}

test "file" {
    const a = std.testing.allocator;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./.git/objects/37/0303630b3fc631a0cb3942860fb6f77446e9c1", .{});
    var d = zlib.decompressor(file.reader());
    const dz = try d.reader().readAllAlloc(a, 0xffff);
    defer a.free(dz);
    const blob = dz[(indexOf(u8, dz, "\x00") orelse unreachable) + 1 ..];
    var commit = try Commit.init(SHA.init("370303630b3fc631a0cb3942860fb6f77446e9c1"), blob);
    //defer commit.raze();
    //std.debug.print("{}\n", .{commit});
    try std.testing.expectEqualStrings("fcb6817b0efc397f1525ff7ee375e08703ed17a9", commit.tree.hex[0..]);
    try std.testing.expectEqualStrings("370303630b3fc631a0cb3942860fb6f77446e9c1", commit.sha.hex[0..]);
}

test "not gpg" {
    const null_sha = SHA.init("0000000000000000000000000000000000000000");
    const blob_invalid_0 =
        \\tree 0000bb21f5276fd4f3611a890d12312312415434
        \\parent ffffff8bd96b1abaceaa3298374ab082f4239948
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
    const commit = try Commit.init(null_sha, blob_invalid_0);
    try std.testing.expect(eql(u8, commit.sha.bin[0..], null_sha.bin[0..]));
}

test "toParent" {
    const a = std.testing.allocator;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd);
    defer repo.raze();
    try repo.loadData(a);
    var commit = try repo.headCommit(a);

    var count: usize = 0;
    while (true) {
        count += 1;
        if (commit.parent[0]) |_| {
            const parent = try commit.toParent(a, 0, &repo);
            commit.raze();

            commit = parent;
        } else break;
    }
    commit.raze();
    try std.testing.expect(count >= 31); // LOL SORRY!
}

test "tree decom" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./.git/objects/5e/dabf724389ef87fa5a5ddb2ebe6dbd888885ae", .{});
    var b: [1 << 16]u8 = undefined;

    var d = zlib.decompressor(file.reader());
    const count = try d.read(&b);
    const buf = try a.dupe(u8, b[0..count]);
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

test "read pack" {
    const a = std.testing.allocator;
    var cwd = std.fs.cwd();
    const dir = try cwd.openDir("repos/hastur", .{});
    var repo = try Repo.init(dir);
    defer repo.raze();

    try repo.loadData(a);
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
    const obj = try repo.loadObject(a, SHA.init(lol));
    defer a.free(obj.memory);
    try std.testing.expect(obj.kind == .commit);
    if (false) std.debug.print("{}\n", .{obj});
}

test "pack contains" {
    const a = std.testing.allocator;
    var cwd = std.fs.cwd();
    const dir = try cwd.openDir("repos/srctree", .{});
    var repo = try Repo.init(dir);
    try repo.loadData(a);
    defer repo.raze();

    const sha = SHA.init("7d4786ded56e1ee6cfe72c7986218e234961d03c");

    var found: bool = false;
    for (repo.packs) |pack| {
        found = pack.contains(sha) != null;
        if (found) break;
    }
    try std.testing.expect(found);

    found = false;
    for (repo.packs) |pack| {
        found = try pack.containsPrefix(sha.bin[0..10]) != null;
        if (found) break;
    }
    try std.testing.expect(found);

    const err = repo.packs[0].containsPrefix(sha.bin[0..1]);
    try std.testing.expectError(error.AmbiguousRef, err);

    //var long_obj = try repo.findObj(a, lol);
}

test "hopefully a delta" {
    const a = std.testing.allocator;
    var cwd = std.fs.cwd();
    const dir = try cwd.openDir("repos/hastur", .{});
    var repo = try Repo.init(dir);
    try repo.loadData(a);
    defer repo.raze();

    var head = try repo.headCommit(a);
    defer head.raze();
    if (false) std.debug.print("{}\n", .{head});

    const obj = try repo.loadPacked(a, head.tree);
    const tree = try Tree.initOwned(head.tree, a, obj.?);
    tree.raze();
    if (false) std.debug.print("{}\n", .{tree});
}

test "commit to tree" {
    const a = std.testing.allocator;
    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd);
    defer repo.raze();

    try repo.loadData(a);

    const cmt = try repo.headCommit(a);
    defer cmt.raze();
    const tree = try cmt.mkTree(a, &repo);
    defer tree.raze();
    if (false) std.debug.print("tree {}\n", .{tree});
    if (false) for (tree.objects) |obj| std.debug.print("    {}\n", .{obj});
}

test "blob to commit" {
    var a = std.testing.allocator;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd);
    try repo.loadData(a);
    defer repo.raze();

    const cmtt = try repo.headCommit(a);
    defer cmtt.raze();

    const tree = try cmtt.mkTree(a, &repo);
    defer tree.raze();

    var timer = try std.time.Timer.start();
    var lap = timer.lap();
    const found = try tree.changedSet(a, &repo);
    if (false) std.debug.print("found {any}\n", .{found});
    for (found) |f| f.raze();
    a.free(found);
    lap = timer.lap();
    if (false) std.debug.print("timer {}\n", .{lap});
}

test "mk sub tree" {
    const a = std.testing.allocator;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd);
    defer repo.raze();

    try repo.loadData(a);

    const cmtt = try repo.headCommit(a);
    defer cmtt.raze();

    var tree = try cmtt.mkTree(a, &repo);
    defer tree.raze();

    var blob: Blob = blb: for (tree.blobs) |obj| {
        if (std.mem.eql(u8, obj.name, "src")) break :blb obj;
    } else return error.ExpectedBlobMissing;
    var subtree = try blob.toTree(a, &repo);
    if (false) std.debug.print("{any}\n", .{subtree});
    for (subtree.blobs) |obj| {
        if (false) std.debug.print("{any}\n", .{obj});
    }

    subtree.raze();
}

test "commit mk sub tree" {
    var a = std.testing.allocator;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd);
    defer repo.raze();

    try repo.loadData(a);

    const cmtt = try repo.headCommit(a);
    defer cmtt.raze();

    var tree = try cmtt.mkTree(a, &repo);
    defer tree.raze();

    var blob: Blob = blb: for (tree.blobs) |obj| {
        if (std.mem.eql(u8, obj.name, "src")) break :blb obj;
    } else return error.ExpectedBlobMissing;
    var subtree = try blob.toTree(a, &repo);
    if (false) std.debug.print("{any}\n", .{subtree});
    for (subtree.blobs) |obj| {
        if (false) std.debug.print("{any}\n", .{obj});
    }
    defer subtree.raze();

    const csubtree = try cmtt.mkSubTree(a, "src", &repo);
    if (false) std.debug.print("{any}\n", .{csubtree});
    csubtree.raze();

    const csubtree2 = try cmtt.mkSubTree(a, "src/endpoints", &repo);
    if (false) std.debug.print("{any}\n", .{csubtree2});
    if (false) for (csubtree2.objects) |obj|
        std.debug.print("{any}\n", .{obj});
    defer csubtree2.raze();

    const changed = try csubtree2.changedSet(a, &repo);
    for (csubtree2.blobs, changed) |o, c| {
        if (false) std.debug.print("{s} {s}\n", .{ o.name, c.sha });
        c.raze();
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
    //defer repo.raze();

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
    defer repo.raze();

    try repo.loadData(a);

    const cmtt = try repo.headCommit(a);
    defer cmtt.raze();

    const tree = try cmtt.mkTree(a, &repo);
    defer tree.raze();

    var timer = try std.time.Timer.start();
    var lap = timer.lap();
    const found = try tree.changedSet(a, &repo);
    if (false) std.debug.print("found {any}\n", .{found});
    for (found) |f| f.raze();
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
    defer new_repo.raze();
}

test "updated at" {
    const a = std.testing.allocator;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd);
    defer repo.raze();

    try repo.loadData(a);
    const oldest = try repo.updatedAt(a);
    _ = oldest;
    //std.debug.print("{}\n", .{oldest});
}

test "list remotes" {
    const a = std.testing.allocator;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd);
    try repo.loadData(a);
    defer repo.raze();
    const remotes = repo.remotes orelse unreachable;
    try std.testing.expect(remotes.len == 2);
    try std.testing.expectEqualStrings("github", remotes[0].name);
    try std.testing.expectEqualStrings("gr.ht", remotes[1].name);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const zlib = std.compress.zlib;
const hexLower = std.fmt.fmtSliceHexLower;
const bufPrint = std.fmt.bufPrint;
const parseInt = std.fmt.parseInt;
const allocPrint = std.fmt.allocPrint;
const AnyReader = std.io.AnyReader;
