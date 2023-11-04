const std = @import("std");

const Allocator = std.mem.Allocator;
const zlib = std.compress.zlib;
const hexLower = std.fmt.fmtSliceHexLower;
const PROT = std.os.PROT;
const MAP = std.os.MAP;

const DateTime = @import("datetime.zig");

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
    PackCorrupt,
};

const Types = enum {
    commit,
    blob,
    tree,
};

const SHA = []const u8; // SUPERBAD, I'm sorry!

const Pack = struct {
    name: SHA,
    pack: []u8,
    idx: []u8,
    pack_fd: std.fs.File,
    idx_fd: std.fs.File,

    pack_header: *Header = undefined,
    idx_header: *IdxHeader = undefined,
    objnames: []u8 = undefined,
    crc: []u32 = undefined,
    offsets: []u32 = undefined,
    hugeoffsets: ?[]u64 = null,

    const Header = extern struct {
        sig: u32 = 0,
        vnum: u32 = 0,
        onum: u32 = 0,
    };

    /// Packfile v2 support only at this time
    /// marked as extern to enable mmaping the header if useful
    const IdxHeader = extern struct {
        magic: u32,
        vnum: u32,
        fanout: [256]u32,
    };

    const ObjType = enum(u3) {
        invalid = 0,
        commit = 1,
        tree = 2,
        blob = 3,
        tag = 4,
        ofs_delta = 6,
        ref_delta = 7,
    };

    const ObjHeader = struct {
        kind: ObjType,
        size: usize,
    };

    /// assumes name ownership
    pub fn init(dir: std.fs.Dir, name: []u8) !Pack {
        var filename: [50]u8 = undefined;
        const ifd = try dir.openFile(try std.fmt.bufPrint(&filename, "{s}.idx", .{name}), .{});
        const pfd = try dir.openFile(try std.fmt.bufPrint(&filename, "{s}.pack", .{name}), .{});
        var pack = Pack{
            .name = name,
            .pack = try mmap(pfd),
            .idx = try mmap(ifd),
            .pack_fd = pfd,
            .idx_fd = ifd,
        };
        try pack.verify();
        return pack;
    }

    fn verify(self: *Pack) !void {
        try self.verifyIdx();
        try self.verifyPack();
    }

    fn verifyIdx(self: *Pack) !void {
        self.idx_header = @alignCast(@ptrCast(self.idx.ptr));
        const count = @byteSwap(self.idx_header.fanout[255]);
        self.objnames = self.idx[258 * 4 ..][0 .. 20 * count];
        self.crc.ptr = @alignCast(@ptrCast(self.idx[258 * 4 + 20 * count ..].ptr));
        self.crc.len = count;
        self.offsets.ptr = @alignCast(@ptrCast(self.idx[258 * 4 + 24 * count ..].ptr));
        self.offsets.len = count;

        self.hugeoffsets = null;
    }

    fn verifyPack(self: *Pack) !void {
        self.idx_header = @alignCast(@ptrCast(self.idx.ptr));
    }

    fn mmap(f: std.fs.File) ![]u8 {
        try f.seekFromEnd(0);
        const length = try f.getPos();
        const offset = 0;
        return std.os.mmap(null, length, PROT.READ, MAP.SHARED, f.handle, offset);
    }

    pub fn fanOut(self: Pack, i: u8) u32 {
        return @byteSwap(self.idx_header.fanout[i]);
    }

    pub fn fanOutCount(self: Pack, i: u8) u32 {
        if (i == 0) return self.fanOut(i);
        return self.fanOut(i) - self.fanOut(i - 1);
    }

    pub fn contains(self: Pack, sha: SHA) ?u32 {
        var start: usize = 0;
        var count: usize = 0;
        if (sha[0] == 0) {
            if (self.fanOut(0) == 0) return null;
            count = self.fanOut(0);
        } else if (self.fanOutCount(sha[0]) > 0) {
            start = self.fanOut(sha[0] - 1);
            count = self.fanOutCount(sha[0]);
        } else return null;

        for (start..start + count) |i| {
            const objname = self.objnames[i * 20 .. (i + 1) * 20];
            if (std.mem.eql(u8, sha, objname)) {
                return @byteSwap(self.offsets[i]);
            }
        }
        return null;
    }

    pub fn getReaderOffset(self: Pack, offset: u32) !FBSReader {
        if (offset > self.pack.len) return error.WTF;
        return self.pack[offset];
    }

    fn parseObjHeader(reader: *FBSReader) Pack.ObjHeader {
        var byte: usize = 0;
        byte = reader.readByte() catch unreachable;
        var h = Pack.ObjHeader{
            .size = byte & 0b1111,
            .kind = @enumFromInt((byte & 0b01110000) >> 4),
        };
        var cont: bool = byte & 0x80 != 0;
        var shift: u6 = 4;
        while (cont) {
            byte = reader.readByte() catch unreachable;
            h.size |= (byte << shift);
            shift += 7;
            cont = byte >= 0x80;
        }
        return h;
    }

    fn loadBlob(a: Allocator, reader: *FBSReader) ![]u8 {
        var _zlib = try zlib.decompressStream(a, reader.*);
        defer _zlib.deinit();
        var zr = _zlib.reader();
        return try zr.readAllAlloc(a, 0xffffff);
    }

    fn readVarInt(reader: *FBSReader) !usize {
        var byte: usize = try reader.readByte();
        var base: usize = byte & 0x7F;
        while (byte >= 0x80) {
            base += 1;
            byte = try reader.readByte();
            base = (base << 7) + (byte & 0x7F);
        }
        //std.debug.print("varint = {}\n", .{base});
        return base;
    }

    fn deltaInst(reader: *FBSReader, writer: anytype, base: []u8) !usize {
        var readb: usize = try reader.readByte();
        if (readb == 0) {
            std.debug.print("INVALID INSTRUCTION 0x00\n", .{});
            @panic("Invalid state :<");
        }
        if (readb >= 0x80) {
            // std.debug.print("COPY {b:0>3} {b:0>4}\n", .{
            //     (readb & 0b1110000) >> 4,
            //     (readb & 0b1111),
            // });
            var offs: usize = 0;
            if (readb & 1 != 0) offs |= @as(usize, try reader.readByte()) << 0;
            if (readb & 2 != 0) offs |= @as(usize, try reader.readByte()) << 8;
            if (readb & 4 != 0) offs |= @as(usize, try reader.readByte()) << 16;
            if (readb & 8 != 0) offs |= @as(usize, try reader.readByte()) << 24;
            //std.debug.print("    offs: {:12} {b:0>32} \n", .{ offs, offs });
            var size: usize = 0;
            if (readb & 16 != 0) size |= @as(usize, try reader.readByte()) << 0;
            if (readb & 32 != 0) size |= @as(usize, try reader.readByte()) << 8;
            if (readb & 64 != 0) size |= @as(usize, try reader.readByte()) << 16;

            if (size == 0) size = 0x10000;
            //std.debug.print("    size: {:12}         {b:0>24} \n", .{ size, size });
            //std.debug.print("COPY {: >4} {: >4}\n", .{ offs, size });
            if (size != try writer.write(base[offs..][0..size])) @panic("write didn't not fail");
            return size;
        } else {
            var stage: [128]u8 = undefined;
            var s = stage[0..readb];
            _ = try reader.read(s);
            _ = try writer.write(s);
            //std.debug.print("INSERT {} \n", .{readb});
            return readb;
        }
    }

    fn loadDelta(self: Pack, a: Allocator, reader: *FBSReader, offset: usize) ![]u8 {
        // fd pos is offset + 2-ish because of the header read
        var srclen = try readVarInt(reader);

        var _zlib = try zlib.decompressStream(a, reader.*);
        defer _zlib.deinit();
        var zr = _zlib.reader();
        var inst = try zr.readAllAlloc(a, 0xffffff);
        defer a.free(inst);
        var inst_fbs = std.io.fixedBufferStream(inst);
        var inst_reader = inst_fbs.reader();
        // We don't actually need these when zlib works :)
        _ = try readVarInt(&inst_reader);
        _ = try readVarInt(&inst_reader);

        const baseobj_offset = offset - srclen;
        var basez = try self.loadObj(a, baseobj_offset);
        defer a.free(basez);

        var buffer = std.ArrayList(u8).init(a);
        while (true) {
            _ = deltaInst(&inst_reader, buffer.writer(), basez) catch {
                break;
            };
        }
        return try buffer.toOwnedSlice();
    }

    fn loadObj(self: Pack, a: Allocator, offset: usize) Error![]u8 {
        var fbs = std.io.fixedBufferStream(self.pack[offset..]);
        var reader = fbs.reader();
        var h = parseObjHeader(&reader);

        switch (h.kind) {
            .commit, .tree, .blob => return loadBlob(a, &reader) catch return error.PackCorrupt,
            .ofs_delta => return self.loadDelta(a, &reader, offset) catch return error.PackCorrupt,
            else => {
                std.debug.print("obj type ({}) not implemened\n", .{h.kind});
                unreachable; // not implemented
            },
        }
        unreachable;
    }

    pub fn getObject(self: Pack, a: Allocator, offset: usize) !Object {
        var data = try self.loadObj(a, offset);
        return Object.init(data);
    }

    pub fn raze(self: Pack, a: Allocator) void {
        self.pack_fd.close();
        self.idx_fd.close();
        std.os.munmap(@alignCast(self.pack));
        std.os.munmap(@alignCast(self.idx));
        a.free(self.name);
    }
};

const Object = struct {
    ctx: union(enum) {
        fs: std.fs.File,
        buf: std.io.FixedBufferStream([]u8),
    },
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

    pub fn init(data: anytype) Object {
        return switch (@TypeOf(data)) {
            std.fs.File => Object{ .ctx = .{ .fs = data } },
            []u8 => Object{ .ctx = .{ .buf = FBS(data) } },
            else => @compileError("This type not implemented in Git Reader"),
        };
    }

    pub const ReadError = error{
        Unknown,
    };

    pub const Reader = std.io.Reader(*Object, ReadError, read);

    fn read(self: *Object, dest: []u8) ReadError!usize {
        return switch (self.ctx) {
            .fs => |*fs| fs.read(dest) catch return ReadError.Unknown,
            .buf => |*b| b.read(dest) catch return ReadError.Unknown,
        };
    }

    pub fn reader(self: *Object) Object.Reader {
        return .{ .context = self };
    }

    pub fn reset(self: *Object) void {
        switch (self.ctx) {
            .buf => |*b| b.pos = 0,
            else => {},
        }
    }

    pub fn raze(self: Object, a: Allocator) void {
        switch (self.ctx) {
            .buf => |b| a.free(b.buffer),
            .fs => |fs| fs.close(),
        }
    }
};

const Reader = Object.Reader;
const FBSReader = std.io.FixedBufferStream([]u8).Reader;
const FsReader = std.fs.File.Reader;

pub const Repo = struct {
    dir: std.fs.Dir,
    packs: []Pack,
    refs: []Ref,
    current: ?[]u8 = null,
    _head: ?[]u8 = null,

    pub fn init(d: std.fs.Dir) Error!Repo {
        var repo = Repo{
            .dir = d,
            .packs = &[0]Pack{},
            .refs = &[0]Ref{},
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

    const empty_sha = [_]u8{0} ** 20;

    fn loadFileObj(self: Repo, in_sha: SHA) !std.fs.File {
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

    fn loadPackDeltaRef(_: *Repo, _: Allocator) ![]u8 {
        return error.NotImplemnted;
    }

    /// TODO binary search lol
    fn findObj(self: Repo, a: Allocator, in_sha: SHA) !Object {
        var shabuf: [20]u8 = undefined;
        var sha: []const u8 = &shabuf;
        if (in_sha.len == 40) {
            for (&shabuf, 0..) |*s, i| {
                s.* = try std.fmt.parseInt(u8, in_sha[i * 2 .. (i + 1) * 2], 16);
            }
            sha.len = 20;
        } else {
            sha = in_sha;
        }

        for (self.packs) |pack| {
            if (pack.contains(sha)) |offset| {
                return try pack.getObject(a, offset);
            }
        }
        if (self.loadFileObj(sha)) |fd| {
            defer fd.close();
            var _zlib = try zlib.decompressStream(a, fd.reader());
            defer _zlib.deinit();
            var reader = _zlib.reader();
            var data = try reader.readAllAlloc(a, 0xffff);
            return Object.init(data);
        } else |_| {}
        return error.ObjectMissing;
    }

    pub fn loadPacks(self: *Repo, a: Allocator) !void {
        var idir = try self.dir.openIterableDir("./objects/pack", .{});
        var itr = idir.iterate();
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

            self.packs[i] = try Pack.init(idir.dir, try a.dupe(u8, file.name[0 .. file.name.len - 4]));
            //self.loadPackIdx(a, fd.reader());
            i += 1;
        }
    }

    pub fn deref() Object {}

    pub fn loadRefs(self: *Repo, a: Allocator) !void {
        var list = std.ArrayList(Ref).init(a);
        var idir = try self.dir.openIterableDir("refs/heads", .{});
        defer idir.close();
        var itr = idir.iterate();
        while (try itr.next()) |file| {
            if (file.kind != .file) {
                std.log.info("Not desending {s} ({})", .{ file.name, file.kind });
                continue;
            }
            var filename = [_]u8{0} ** 2048;
            var fname: []u8 = &filename;
            fname = try std.fmt.bufPrint(&filename, "./refs/heads/{s}", .{file.name});
            var f = try self.dir.openFile(fname, .{});
            defer f.close();
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
        self.refs = try list.toOwnedSlice();
    }

    /// TODO write the real function that goes here
    pub fn ref(self: Repo, str: []const u8) !SHA {
        for (self.refs) |r| {
            switch (r) {
                .tag => unreachable,
                .branch => |b| {
                    if (std.mem.eql(u8, b.name, str)) {
                        return b.sha;
                    }
                },
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
        if (self.refs.len == 0) try self.loadRefs(a);
        var f = try self.dir.openFile("HEAD", .{});
        defer f.close();
        const name = try f.readToEndAlloc(a, 0xFF);
        if (!std.mem.eql(u8, name[0..5], "ref: ")) {
            std.debug.print("unexpected HEAD {s}\n", .{name});
            unreachable;
        }
        self._head = name;

        return .{
            .branch = Branch{
                .name = name[5 .. name.len - 1],
                .sha = try self.ref(name[16 .. name.len - 1]),
                .repo = self,
            },
        };
    }

    pub fn commit(self: *Repo, a: Allocator) !Commit {
        var head = try self.HEAD(a);
        var resolv = try self.ref(head.branch.name["refs/heads/".len..]);
        var obj = try self.findObj(a, resolv);
        defer obj.raze(a);
        var cmt = try Commit.fromReader(a, resolv, obj.reader());
        cmt.repo = self;
        return cmt;
    }

    pub fn blob(self: Repo, a: Allocator, sha: SHA) !Object {
        var obj = try self.findObj(a, sha);
        // Yes, I know, but it might be a file :/
        const r = obj.reader();
        const blobb = try r.readAllAlloc(a, 0xffff);

        if (std.mem.indexOf(u8, blobb, "\x00")) |i| {
            return Object.init(blobb[i + 1 ..]);
        }
        obj.reset();
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
        if (self._head) |h| a.free(h);
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

const GPGSig = struct {};

pub const Commit = struct {
    blob: []const u8,
    sha: SHA,
    tree: SHA,
    parent: [3]?SHA,
    author: Actor,
    committer: Actor,
    message: []const u8,
    repo: ?*Repo = null,
    gpgsig: GPGSig,

    ptr_parent: ?*Commit = null, // TOOO multiple parents

    fn header(self: *Commit, data: []const u8) !void {
        if (std.mem.indexOf(u8, data, " ")) |brk| {
            const name = data[0..brk];
            const payload = data[brk..];
            if (std.mem.eql(u8, name, "commit")) {
                if (std.mem.indexOf(u8, data, "\x00")) |nl| {
                    self.tree = payload[nl..][0..40];
                } else unreachable;
            } else if (std.mem.eql(u8, name, "tree")) {
                self.tree = payload[1..41];
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
            } else {
                std.debug.print("unknown header: {s}\n", .{name});
                return error.UnknownHeader;
            }
        } else return error.MalformedHeader;
    }

    /// TODO this
    fn gpgSig(_: *Commit, itr: *std.mem.SplitIterator(u8, .sequence)) !void {
        while (itr.next()) |line| {
            if (std.mem.indexOf(u8, line, "-----END PGP SIGNATURE-----") != null) return;
        }
        return error.InvalidGpgsig;
    }

    pub fn make(sha: SHA, data: []const u8) !Commit {
        var lines = std.mem.split(u8, data, "\n");
        var self: Commit = undefined;
        self.repo = null;
        self.parent = .{ null, null, null }; // I don't like it either, but... lazy
        self.blob = data;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "gpgsig")) {
                try self.gpgSig(&lines);
                continue;
            }
            if (line.len == 0) break;

            self.header(line) catch |e| {
                std.debug.print("header failed {} '{s}'\n", .{ e, line });
                return e;
            };
        }
        self.message = lines.rest();
        self.sha = sha;
        return self;
    }

    pub fn fromReader(a: Allocator, sha: SHA, reader: Reader) !Commit {
        var buf = try reader.readAllAlloc(a, 0xFFFF);
        var self = try make(sha, buf);
        self.blob = buf;
        self.sha = sha;
        return self;
    }

    pub fn toParent(self: *Commit, a: Allocator, idx: u8) !Commit {
        if (idx >= self.parent.len) return error.NoParent;
        if (self.parent[idx]) |parent| {
            if (self.repo) |repo| {
                var obj = try repo.findObj(a, parent);
                defer obj.raze(a);
                var cmt = try Commit.fromReader(a, parent, obj.reader());
                cmt.repo = repo;
                return cmt;
            }
            return error.DetachedCommit;
        }
        return error.NoParent;
    }

    pub fn mkTree(self: Commit, a: Allocator) !Tree {
        if (self.repo) |repo| {
            return try Tree.fromRepo(a, repo.*, self.tree);
        } else return error.DetachedCommit;
    }

    /// Warning; this function is probably unsafe
    pub fn raze(self: Commit, a: Allocator) void {
        a.free(self.blob);
    }
    pub fn format(self: Commit, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        try out.print(
            \\Commit{{
            \\commit {s}
            \\tree {s}
            \\
        , .{ self.sha, self.tree });
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

pub const Blob = struct {
    mode: [6]u8,
    name: []const u8,
    hash: [40]u8,

    pub fn isFile(self: Blob) bool {
        return self.mode[0] != 48;
    }

    pub fn format(self: Blob, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        if (self.isFile())
            try out.print(
                "Blob{{ File {s} @ {s} }}",
                .{ self.name, self.hash },
            )
        else
            try out.print(
                "Blob{{ Tree {s} @ {s} }}",
                .{ self.name, self.hash },
            );
    }
};

pub const Tree = struct {
    blob: []const u8,
    objects: []Blob,

    pub fn fromRepo(a: Allocator, r: Repo, sha: SHA) !Tree {
        var blob = try r.findObj(a, sha);
        defer blob.raze(a);
        var b = try blob.reader().readAllAlloc(a, 0xffff);
        return try Tree.make(a, b);
    }

    pub fn fromReader(a: Allocator, reader: Reader) !Tree {
        var buf = try reader.readAllAlloc(a, 0xffff);
        return try Tree.make(a, buf);
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
                i = index + 1;
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

    pub fn raze(self: Tree, a: Allocator) void {
        a.free(self.objects);
        a.free(self.blob);
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
    var d = try zlib.decompressStream(a, file.reader());
    defer d.deinit();
    var dz = try d.reader().readAllAlloc(a, 0xffff);
    var buffer = Object.init(dz);
    defer buffer.raze(a);
    const commit = try Commit.fromReader(a, "370303630b3fc631a0cb3942860fb6f77446e9c1", buffer.reader());
    defer a.free(commit.blob);
    //std.debug.print("{}\n", .{commit});
    try std.testing.expectEqualStrings("fcb6817b0efc397f1525ff7ee375e08703ed17a9", commit.tree);
    try std.testing.expectEqualStrings("370303630b3fc631a0cb3942860fb6f77446e9c1", commit.sha);
}

test "toParent" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();

    var repo = try Repo.init(cwd);
    defer repo.raze(a);
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
    var _zlib = try zlib.decompressStream(a, file.reader());
    defer _zlib.deinit();
    var reader = _zlib.reader();
    var data = try reader.readAllAlloc(a, 0xffff);
    defer a.free(data);
    var buffer = Object.init(data);
    const commit = try Commit.fromReader(a, "370303630b3fc631a0cb3942860fb6f77446e9c1", buffer.reader());
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
    defer a.free(commit.blob);
    if (false) std.debug.print("{}\n", .{commit});
}

test "hopefully a delta" {
    var a = std.testing.allocator;
    var cwd = std.fs.cwd();
    var dir = try cwd.openDir("repos/hastur", .{});
    var repo = try Repo.init(dir);
    defer repo.raze(a);

    try repo.loadPacks(a);

    var head = try repo.commit(a);
    defer a.free(head.blob);
    //std.debug.print("{}\n", .{head});

    var obj = try repo.findObj(a, head.tree);
    defer obj.raze(a);
    const tree = try Tree.fromReader(a, obj.reader());
    defer a.free(tree.blob);
    defer a.free(tree.objects);
    if (false) std.debug.print("{}\n", .{tree});
}

test "commit to tree" {
    var a = std.testing.allocator;
    var cwd = std.fs.cwd();
    var repo = try Repo.init(cwd);
    defer repo.raze(a);

    //try repo.loadPacks(a);

    const cmt = try repo.commit(a);
    defer cmt.raze(a);
    const tree = try cmt.mkTree(a);
    defer tree.raze(a);
    if (false) std.debug.print("tree {}\n", .{tree});
    if (false) for (tree.objects) |obj| std.debug.print("    {}\n", .{obj});
}
