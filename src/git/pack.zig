const std = @import("std");
const Allocator = std.mem.Allocator;
const zlib = std.compress.zlib;
const PROT = std.posix.PROT;
const MAP_TYPE = std.os.linux.MAP_TYPE;

const Git = @import("../git.zig");
const Error = Git.Error;
const FBSReader = Git.FBSReader;
const Repo = Git.Repo;
const shaToHex = Git.shaToHex;

const SHA = Git.SHA;

pub const Pack = @This();

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
