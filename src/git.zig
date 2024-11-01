const std = @import("std");

const Allocator = std.mem.Allocator;
const zlib = std.compress.zlib;
const hexLower = std.fmt.fmtSliceHexLower;
const PROT = std.posix.PROT;
const MAP_TYPE = std.os.linux.MAP_TYPE;

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

const SHA = []const u8; // SUPERBAD, I'm sorry!

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
        std.debug.assert(name.len <= 45);
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
        try pack.prepare();
        return pack;
    }

    fn prepare(self: *Pack) !void {
        try self.prepareIdx();
        try self.preparePack();
    }

    fn prepareIdx(self: *Pack) !void {
        self.idx_header = @alignCast(@ptrCast(self.idx.ptr));
        const count = @byteSwap(self.idx_header.fanout[255]);
        self.objnames = self.idx[258 * 4 ..][0 .. 20 * count];
        self.crc.ptr = @alignCast(@ptrCast(self.idx[258 * 4 + 20 * count ..].ptr));
        self.crc.len = count;
        self.offsets.ptr = @alignCast(@ptrCast(self.idx[258 * 4 + 24 * count ..].ptr));
        self.offsets.len = count;

        self.hugeoffsets = null;
    }

    fn preparePack(self: *Pack) !void {
        self.idx_header = @alignCast(@ptrCast(self.idx.ptr));
    }

    fn mmap(f: std.fs.File) ![]u8 {
        try f.seekFromEnd(0);
        const length = try f.getPos();
        const offset = 0;
        return std.posix.mmap(null, length, PROT.READ, .{ .TYPE = .SHARED }, f.handle, offset);
    }

    fn munmap(mem: []align(std.mem.page_size) const u8) void {
        std.posix.munmap(mem);
    }

    /// the packidx fanout is a 0xFF count table of u32 the sum count for that
    /// byte which translates the start position for that byte in the main table
    pub fn fanOut(self: Pack, i: u8) u32 {
        return @byteSwap(self.idx_header.fanout[i]);
    }

    pub fn fanOutCount(self: Pack, i: u8) u32 {
        if (i == 0) return self.fanOut(i);
        return self.fanOut(i) - self.fanOut(i - 1);
    }

    pub fn contains(self: Pack, sha: SHA) ?u32 {
        std.debug.assert(sha.len == 20);
        return self.containsPrefix(sha) catch unreachable;
    }

    pub fn containsPrefix(self: Pack, sha: SHA) !?u32 {
        const count: usize = self.fanOutCount(sha[0]);
        if (count == 0) return null;

        const start: usize = if (sha[0] > 0) self.fanOut(sha[0] - 1) else 0;

        const objnames = self.objnames[start * 20 ..][0 .. count * 20];
        for (0..count) |i| {
            const objname = objnames[i * 20 ..][0..20];
            if (std.mem.eql(u8, sha, objname[0..sha.len])) {
                if (objnames.len > i * 20 + 20 and std.mem.eql(u8, sha, objnames[i * 20 + 20 ..][0..sha.len])) {
                    return error.AmbiguousRef;
                }
                return @byteSwap(self.offsets[i + start]);
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
        var _zlib = zlib.decompressor(reader.*);
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
        const readb: usize = try reader.readByte();
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
            if (size != try writer.write(base[offs..][0..size]))
                @panic("write didn't not fail");
            return size;
        } else {
            var stage: [128]u8 = undefined;
            const s = stage[0..readb];
            _ = try reader.read(s);
            _ = try writer.write(s);
            //std.debug.print("INSERT {} \n", .{readb});
            return readb;
        }
    }

    fn loadRefDelta(_: Pack, a: Allocator, reader: *FBSReader, _: usize, repo: Repo) ![]u8 {
        var buf: [20]u8 = undefined;
        var hexy: [40]u8 = undefined;

        _ = try reader.read(&buf);
        shaToHex(&buf, &hexy);
        const basez = repo.findBlob(a, &buf) catch return error.BlobMissing;
        defer a.free(basez);

        var _zlib = zlib.decompressor(reader.*);
        var zr = _zlib.reader();
        const inst = zr.readAllAlloc(a, 0xffffff) catch return error.PackCorrupt;
        defer a.free(inst);
        var inst_fbs = std.io.fixedBufferStream(inst);
        var inst_reader = inst_fbs.reader();
        // We don't actually need these when zlib works :)
        _ = try readVarInt(&inst_reader);
        _ = try readVarInt(&inst_reader);
        var buffer = std.ArrayList(u8).init(a);
        while (true) {
            _ = deltaInst(&inst_reader, buffer.writer(), basez) catch {
                break;
            };
        }
        return try buffer.toOwnedSlice();
    }

    fn loadDelta(self: Pack, a: Allocator, reader: *FBSReader, offset: usize, repo: Repo) ![]u8 {
        // fd pos is offset + 2-ish because of the header read
        const srclen = try readVarInt(reader);

        var _zlib = zlib.decompressor(reader.*);
        var zr = _zlib.reader();
        const inst = zr.readAllAlloc(a, 0xffffff) catch return error.PackCorrupt;
        defer a.free(inst);
        var inst_fbs = std.io.fixedBufferStream(inst);
        var inst_reader = inst_fbs.reader();
        // We don't actually need these when zlib works :)
        _ = try readVarInt(&inst_reader);
        _ = try readVarInt(&inst_reader);

        const baseobj_offset = offset - srclen;
        const basez = try self.loadObj(a, baseobj_offset, repo);
        defer a.free(basez);

        var buffer = std.ArrayList(u8).init(a);
        while (true) {
            _ = deltaInst(&inst_reader, buffer.writer(), basez) catch {
                break;
            };
        }
        return try buffer.toOwnedSlice();
    }

    pub fn loadObj(self: Pack, a: Allocator, offset: usize, repo: Repo) Error![]u8 {
        var fbs = std.io.fixedBufferStream(self.pack[offset..]);
        var reader = fbs.reader();
        const h = parseObjHeader(&reader);

        switch (h.kind) {
            .commit, .tree, .blob => return loadBlob(a, &reader) catch return error.PackCorrupt,
            .ofs_delta => return try self.loadDelta(a, &reader, offset, repo),
            .ref_delta => return try self.loadRefDelta(a, &reader, offset, repo),
            else => {
                std.debug.print("obj type ({}) not implemened\n", .{h.kind});
                unreachable; // not implemented
            },
        }
        unreachable;
    }

    pub fn raze(self: Pack, a: Allocator) void {
        self.pack_fd.close();
        self.idx_fd.close();
        munmap(@alignCast(self.pack));
        munmap(@alignCast(self.idx));
        a.free(self.name);
    }
};

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

const Reader = Object.Reader;
const FBSReader = std.io.FixedBufferStream([]u8).Reader;
const FsReader = std.fs.File.Reader;

pub const Repo = struct {
    bare: bool,
    dir: std.fs.Dir,
    packs: []Pack,
    refs: []Ref,
    current: ?[]u8 = null,
    head: ?Ref = null,

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

    fn findBlob(self: Repo, a: Allocator, sha: SHA) ![]u8 {
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
    fn findObj(self: Repo, a: Allocator, in_sha: SHA) !Object {
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

pub const Tag = struct {
    name: []const u8,
    sha: SHA,
};

pub const Ref = union(enum) {
    tag: Tag,
    branch: Branch,
    sha: SHA,
    missing: void,
};

pub const Actor = struct {
    name: []const u8,
    email: []const u8,
    timestr: []const u8,
    tzstr: []const u8,
    timestamp: i64 = 0,
    /// TODO: This will not remain i64
    tz: i64 = 0,

    pub fn make(data: []const u8) !Actor {
        var itr = std.mem.splitBackwards(u8, data, " ");
        const tzstr = itr.next() orelse return error.ActorParse;
        const epoch = itr.next() orelse return error.ActorParse;
        const epstart = itr.index orelse return error.ActorParse;
        const email = itr.next() orelse return error.ActorParse;
        const name = itr.rest();

        return .{
            .name = name,
            .email = email,
            .timestr = data[epstart..data.len],
            .tzstr = tzstr,
            .timestamp = std.fmt.parseInt(i64, epoch, 10) catch return error.ActorParse,
        };
    }

    pub fn format(self: Actor, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        try out.print("Actor{{ name {s}, email {s} time {} }}", .{ self.name, self.email, self.timestamp });
    }
};

pub const Commit = struct {
    // TODO not currently implemented
    const GPGSig = struct {};

    alloc: ?Allocator = null,
    blob: []const u8,
    sha: SHA,
    tree: SHA,
    /// 9 ought to be enough for anyone... or at least robinli ... at least for a while
    /// TODO fix and make this dynamic
    parent: [9]?SHA,
    author: Actor,
    committer: Actor,
    /// Raw message including the title and body
    message: []const u8,
    title: []const u8,
    body: []const u8,
    repo: ?*const Repo = null,
    gpgsig: ?GPGSig,

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
            if (std.mem.indexOf(u8, line, "-----END SSH SIGNATURE-----") != null) return;
        }
        return error.InvalidGpgsig;
    }

    pub fn initAlloc(a: Allocator, sha_in: SHA, data: []const u8) !Commit {
        const sha = try a.dupe(u8, sha_in);
        const blob = try a.dupe(u8, data);

        var self = try make(sha, blob, a);
        self.alloc = a;
        return self;
    }

    pub fn init(sha: SHA, data: []const u8) !Commit {
        return make(sha, data, null);
    }

    pub fn make(sha: SHA, data: []const u8, a: ?Allocator) !Commit {
        _ = a;
        var lines = std.mem.split(u8, data, "\n");
        var self: Commit = undefined;
        self.repo = null;
        // I don't like it either, but... lazy
        self.parent = .{ null, null, null, null, null, null, null, null, null };
        self.blob = data;
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "gpgsig")) {
                self.gpgSig(&lines) catch |e| {
                    std.debug.print("GPG sig failed {}\n", .{e});
                    std.debug.print("full stack '''\n{s}\n'''\n", .{data});
                    return e;
                };
                continue;
            }
            if (line.len == 0) break;
            // Seen in GPG headers set by github... thanks github :<
            if (std.mem.trim(u8, line, " \t").len != line.len) continue;

            self.header(line) catch |e| {
                std.debug.print("header failed {} on {} '{s}'\n", .{ e, lines.index.?, line });
                std.debug.print("full stack '''\n{s}\n'''\n", .{data});
                return e;
            };
        }
        self.message = lines.rest();
        if (std.mem.indexOf(u8, self.message, "\n\n")) |nl| {
            self.title = self.message[0..nl];
            self.body = self.message[nl + 2 ..];
        } else {
            self.title = self.message;
            self.body = self.message[0..0];
        }
        self.sha = sha;
        return self;
    }

    pub fn fromReader(a: Allocator, sha: SHA, reader: Reader) !Commit {
        var buffer: [0xFFFF]u8 = undefined;
        const len = try reader.readAll(&buffer);
        return try initAlloc(a, sha, buffer[0..len]);
    }

    pub fn toParent(self: Commit, a: Allocator, idx: u8) !Commit {
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

    pub fn mkSubTree(self: Commit, a: Allocator, subpath: ?[]const u8) !Tree {
        const path = subpath orelse return self.mkTree(a);
        if (path.len == 0) return self.mkTree(a);

        var itr = std.mem.split(u8, path, "/");
        var root = try self.mkTree(a);
        root.path = try a.dupe(u8, path);
        iter: while (itr.next()) |p| {
            for (root.objects) |obj| {
                if (std.mem.eql(u8, obj.name, p)) {
                    if (itr.rest().len == 0) {
                        defer root.raze(a);
                        var out = try obj.toTree(a, self.repo.?.*);
                        out.path = try a.dupe(u8, path);
                        return out;
                    } else {
                        const tree = try obj.toTree(a, self.repo.?.*);
                        defer root = tree;
                        root.raze(a);
                        continue :iter;
                    }
                }
            } else return error.PathNotFound;
        }
        return root;
    }

    /// Warning; this function is probably unsafe
    pub fn raze(self: Commit) void {
        if (self.alloc) |a| {
            a.free(self.sha);
            a.free(self.blob);
        }
    }

    pub fn format(
        self: Commit,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        out: anytype,
    ) !void {
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

pub const Blob = struct {
    mode: [6]u8,
    name: []const u8,
    hash: [40]u8,

    pub fn isFile(self: Blob) bool {
        return self.mode[0] != 48;
    }

    pub fn toObject(self: Blob, a: Allocator, repo: Repo) !Object {
        if (!self.isFile()) return error.NotAFile;
        _ = a;
        _ = repo;
        return error.NotImplemented;
    }

    pub fn toTree(self: Blob, a: Allocator, repo: Repo) !Tree {
        if (self.isFile()) return error.NotATree;
        const tree = try Tree.fromRepo(a, repo, &self.hash);
        return tree;
    }

    pub fn format(self: Blob, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        try out.print("Blob{{ ", .{});
        try if (self.isFile()) out.print("File", .{}) else out.print("Tree", .{});
        try out.print(" {s} @ {s} }}", .{ self.name, self.hash });
    }
};

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

pub const Tree = struct {
    sha: []const u8,
    path: ?[]const u8 = null,
    blob: []const u8,
    objects: []Blob,

    pub fn pushPath(self: *Tree, a: Allocator, path: []const u8) !void {
        const spath = self.path orelse {
            self.path = try a.dupe(u8, path);
            return;
        };

        self.path = try std.mem.join(a, "/", &[_][]const u8{ spath, path });
        a.free(spath);
    }

    pub fn fromRepo(a: Allocator, r: Repo, sha: SHA) !Tree {
        var blob = try r.findObj(a, sha);
        defer blob.raze(a);
        const b = try blob.reader().readAllAlloc(a, 0xffff);
        return try Tree.make(a, sha, b);
    }

    pub fn make(a: Allocator, sha: SHA, blob: []const u8) !Tree {
        var self: Tree = .{
            .sha = try a.dupe(u8, sha),
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

    pub fn fromReader(a: Allocator, sha: SHA, reader: Reader) !Tree {
        const buf = try reader.readAllAlloc(a, 0xffff);
        return try Tree.make(a, sha, buf);
    }

    pub fn changedSet(self: Tree, a: Allocator, repo: *Repo) ![]ChangeSet {
        const cmtt = try repo.headCommit(a);
        defer cmtt.raze();
        const search_list: []?Blob = try a.alloc(?Blob, self.objects.len);
        for (self.objects, search_list) |src, *dst| {
            dst.* = src;
        }
        defer a.free(search_list);

        var par = try repo.headCommit(a);
        var ptree = try par.mkSubTree(a, self.path);

        var changed = try a.alloc(ChangeSet, self.objects.len);
        var old = par;
        var oldtree = ptree;
        var found: usize = 0;
        while (found < search_list.len) {
            old = par;
            oldtree = ptree;
            par = par.toParent(a, 0) catch |err| switch (err) {
                error.NoParent => {
                    for (search_list, 0..) |search_ish, i| {
                        if (search_ish) |search| {
                            found += 1;
                            changed[i] = try ChangeSet.init(
                                a,
                                search.name,
                                old.sha,
                                old.message,
                                old.committer.timestamp,
                            );
                        }
                    }
                    old.raze();
                    oldtree.raze(a);
                    break;
                },
                else => |e| return e,
            };
            ptree = par.mkSubTree(a, self.path) catch |err| switch (err) {
                error.PathNotFound => {
                    for (search_list, 0..) |search_ish, i| {
                        if (search_ish) |search| {
                            found += 1;
                            changed[i] = try ChangeSet.init(
                                a,
                                search.name,
                                old.sha,
                                old.message,
                                old.committer.timestamp,
                            );
                        }
                    }
                    old.raze();
                    oldtree.raze(a);
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
                    changed[i] = try ChangeSet.init(
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
            oldtree.raze(a);
        }

        par.raze();
        ptree.raze(a);
        return changed;
    }

    pub fn raze(self: Tree, a: Allocator) void {
        a.free(self.sha);
        if (self.path) |p| a.free(p);
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

const DEBUG_GIT_ACTIONS = false;

pub const Agent = struct {
    alloc: Allocator,
    repo: ?*const Repo = null,
    cwd: ?std.fs.Dir = null,

    pub fn updateUpstream(self: Agent, branch: []const u8) !bool {
        const fetch = try self.exec(&[_][]const u8{
            "git",
            "fetch",
            "upstream",
            "-q",
        });
        if (fetch.len > 0) std.debug.print("fetch {s}\n", .{fetch});
        self.alloc.free(fetch);

        var buf: [512]u8 = undefined;
        const up_branch = try std.fmt.bufPrint(&buf, "upstream/{s}", .{branch});
        const pull = try self.execCustom(&[_][]const u8{
            "git",
            "merge-base",
            "--is-ancestor",
            "HEAD",
            up_branch,
        });
        defer self.alloc.free(pull.stdout);
        defer self.alloc.free(pull.stderr);

        if (pull.term.Exited == 0) {
            const move = try self.exec(&[_][]const u8{
                "git",
                "fetch",
                "upstream",
                "*:*",
                "-q",
            });
            self.alloc.free(move);
            return true;
        } else {
            std.debug.print("refusing to move head non-ancestor\n", .{});
            return false;
        }
    }

    pub fn updateDownstream(self: Agent) !bool {
        const push = try self.exec(&[_][]const u8{
            "git",
            "push",
            "downstream",
            "*:*",
            "--porcelain",
        });
        std.debug.print("pushing downstream ->\n{s}\n", .{push});
        self.alloc.free(push);
        return true;
    }

    pub fn forkRemote(self: Agent, uri: []const u8, local_dir: []const u8) ![]u8 {
        return try self.exec(&[_][]const u8{
            "git",
            "clone",
            "--bare",
            "--origin",
            "upstream",
            uri,
            local_dir,
        });
    }

    pub fn initRepo(self: Agent, dir: []const u8, opt: struct { bare: bool = true }) ![]u8 {
        return try self.exec(&[_][]const u8{
            "git",
            "init",
            if (opt.bare) "--bare" else "",
            dir,
        });
    }

    pub fn show(self: Agent, sha: []const u8) ![]u8 {
        return try self.exec(&[_][]const u8{
            "git",
            "show",
            "--diff-merges=1",
            "-p",
            sha,
        });
    }

    pub fn blame(self: Agent, name: []const u8) ![]u8 {
        std.debug.print("{s}\n", .{name});
        return try self.exec(&[_][]const u8{
            "git",
            "blame",
            "--porcelain",
            name,
        });
    }

    fn execCustom(self: Agent, argv: []const []const u8) !std.ChildProcess.RunResult {
        std.debug.assert(std.mem.eql(u8, argv[0], "git"));
        const cwd = if (self.cwd != null and self.cwd.?.fd != std.fs.cwd().fd) self.cwd else null;
        const child = std.ChildProcess.run(.{
            .cwd_dir = cwd,
            .allocator = self.alloc,
            .argv = argv,
            .max_output_bytes = 0x1FFFFF,
        }) catch |err| {
            const errstr =
                \\git agent error:
                \\error :: {}
                \\argv :: 
            ;
            std.debug.print(errstr, .{err});
            for (argv) |arg| std.debug.print("{s} ", .{arg});
            std.debug.print("\n", .{});
            return err;
        };
        return child;
    }

    fn exec(self: Agent, argv: []const []const u8) ![]u8 {
        const child = try self.execCustom(argv);
        if (child.stderr.len > 0) std.debug.print("git Agent error\nstderr {s}\n", .{child.stderr});
        self.alloc.free(child.stderr);

        if (DEBUG_GIT_ACTIONS) std.debug.print(
            \\git action
            \\{s}
            \\'''
            \\{s}
            \\'''
            \\
        , .{ argv[1], child.stdout });
        return child.stdout;
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
