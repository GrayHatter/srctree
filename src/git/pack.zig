pack: []u8,
idx: []u8,

pack_header: *Header = undefined,
idx_header: *IdxHeader = undefined,
objnames: []u8 = undefined,
crc: []u32 = undefined,
offsets: []u32 = undefined,
hugeoffsets: ?[]u64 = null,

const Pack = @This();

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

const PackedObjectTypes = enum(u3) {
    invalid = 0,
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,
};

pub const PackedObject = struct {
    const Header = struct {
        kind: PackedObjectTypes,
        size: usize,
    };
    header: PackedObject.Header,
    data: []u8,
};

/// assumes name ownership
pub fn init(dir: std.fs.Dir, name: []const u8) !Pack {
    std.debug.assert(name.len <= 45);
    var filename: [50]u8 = undefined;
    const ifd = try dir.openFile(try bufPrint(&filename, "{s}.idx", .{name}), .{});
    defer ifd.close();
    const pfd = try dir.openFile(try bufPrint(&filename, "{s}.pack", .{name}), .{});
    defer pfd.close();
    var pack = Pack{
        .pack = try mmap(pfd),
        .idx = try mmap(ifd),
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
    return system.mmap(f.handle, try f.getEndPos(), .{});
}

fn munmap(mem: []align(std.heap.page_size_min) const u8) void {
    system.munmap(mem);
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
    return self.containsPrefix(sha.bin[0..]) catch unreachable;
}

fn orderSha(lhs: []const u8, rhs: []const u8) std.math.Order {
    for (lhs, rhs) |l, r| {
        if (l > r) return .gt;
        if (l < r) return .lt;
    }
    return .eq;
}

pub fn containsPrefix(self: Pack, par_sha: []const u8) !?u32 {
    std.debug.assert(par_sha.len <= 20);
    const count: usize = self.fanOutCount(par_sha[0]);
    if (count == 0) return null;

    const start: usize = if (par_sha[0] > 0) self.fanOut(par_sha[0] - 1) else 0;

    const objnames = @as([*][20]u8, @ptrCast(self.objnames[start * 20 ..][0 .. count * 20]))[0..count];

    var left: usize = 0;
    var right: usize = objnames.len;
    //var b_idx: usize = 0;
    var found: ?usize = null;

    while (left < right) {
        const mid = left + (right - left) / 2;

        switch (orderSha(par_sha, objnames[mid][0..par_sha.len])) {
            .eq => {
                found = mid;
                break;
            },
            .gt => left = mid + 1,
            .lt => right = mid,
        }
    }

    if (found) |f| {
        if (objnames.len > f + 1 and eql(u8, par_sha, objnames[f + 1][0..par_sha.len])) {
            return error.AmbiguousRef;
        }
        if (f > 1 and eql(u8, par_sha, objnames[f - 1][0..par_sha.len])) {
            return error.AmbiguousRef;
        }
        return @byteSwap(self.offsets[f + start]);
    }

    //for (0..count) |i| {
    //    const objname = objnames[i];
    //    if (eql(u8, par_sha, objname[0..par_sha.len])) {
    //        if (objnames.len > i + 1 and eql(u8, par_sha, objnames[i + 1][0..par_sha.len])) {
    //            return error.AmbiguousRef;
    //        }
    //        return @byteSwap(self.offsets[i + start]);
    //    }
    //}
    return null;
}

pub fn expandPrefix(self: Pack, psha: []const u8) !?SHA {
    const count: usize = self.fanOutCount(psha[0]);
    if (count == 0) return null;

    const start: usize = if (psha[0] > 0) self.fanOut(psha[0] - 1) else 0;

    const objnames = self.objnames[start * 20 ..][0 .. count * 20];
    for (0..count) |i| {
        const objname = objnames[i * 20 ..][0..20];
        if (eql(u8, psha, objname[0..psha.len])) {
            if (objnames.len > i * 20 + 20 and eql(u8, psha, objnames[i * 20 + 20 ..][0..psha.len])) {
                return error.AmbiguousRef;
            }
            return SHA.init(objname);
        }
    }
    return null;
}

pub fn getReaderOffset(self: Pack, offset: u32) !AnyReader {
    if (offset > self.pack.len) return error.WTF;
    return self.pack[offset];
}

fn parseObjHeader(reader: *AnyReader) PackedObject.Header {
    var byte: usize = 0;
    byte = reader.readByte() catch unreachable;
    var h = PackedObject.Header{
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

fn loadBlob(a: Allocator, reader: *AnyReader) ![]u8 {
    var zlib_ = zlib.decompressor(reader.*);
    return try zlib_.reader().readAllAlloc(a, 0xffffff);
}

fn readVarInt(reader: *AnyReader) error{ReadError}!usize {
    var byte: usize = reader.readByte() catch return error.ReadError;
    var base: usize = byte & 0x7F;
    while (byte >= 0x80) {
        base += 1;
        byte = reader.readByte() catch return error.ReadError;
        base = (base << 7) + (byte & 0x7F);
    }
    //std.debug.print("varint = {}\n", .{base});
    return base;
}

fn deltaInst(reader: *AnyReader, writer: anytype, base: []const u8) !usize {
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

fn loadRefDelta(_: Pack, a: Allocator, reader: *AnyReader, _: usize, repo: *const Repo) Error!PackedObject {
    var buf: [20]u8 = undefined;

    if (reader.read(&buf)) |count| {
        if (count != 20) return error.PackCorrupt;
    } else |_| return error.ReadError;
    const sha = SHA.init(buf[0..]);
    // I hate it too... but I need a break
    var basefree: []u8 = undefined;
    var basedata: []const u8 = undefined;
    var basetype: PackedObjectTypes = undefined;
    switch (repo.loadObjectOrDelta(a, sha) catch return error.BlobMissing) {
        .pack => |pk| {
            basefree = pk.data;
            basedata = pk.data;
            basetype = pk.header.kind;
        },
        .file => |fdata| switch (fdata) {
            .blob => |b| {
                basefree = b.memory.?;
                basedata = b.data.?;
                basetype = .blob;
            },
            .tree => |t| {
                basefree = t.memory.?;
                basedata = t.blob;
                basetype = .tree;
            },
            .commit => |c| {
                basefree = c.memory.?;
                basedata = c.body;
                basetype = .commit;
            },
            .tag => |t| {
                basefree = t.memory.?;
                basedata = t.memory.?;
                basetype = .tag;
            },
        },
    }
    defer a.free(basefree);

    var zlib_ = zlib.decompressor(reader.*);
    const inst = zlib_.reader().readAllAlloc(a, 0xffffff) catch return error.PackCorrupt;
    defer a.free(inst);
    var inst_fbs = std.io.fixedBufferStream(inst);
    var inst_reader = inst_fbs.reader().any();
    // We don't actually need these when zlib works :)
    _ = try readVarInt(&inst_reader);
    _ = try readVarInt(&inst_reader);
    var buffer = std.ArrayList(u8).init(a);
    while (true) {
        _ = deltaInst(&inst_reader, buffer.writer(), basedata) catch {
            break;
        };
    }
    return .{
        .header = .{
            .size = 0,
            .kind = basetype,
        },
        .data = try buffer.toOwnedSlice(),
    };
}

fn loadDelta(self: Pack, a: Allocator, reader: *AnyReader, offset: usize, repo: *const Repo) Error!PackedObject {
    // fd pos is offset + 2-ish because of the header read
    const srclen = try readVarInt(reader);

    var zlib_ = zlib.decompressor(reader.*);
    const inst = zlib_.reader().readAllAlloc(a, 0xffffff) catch return error.PackCorrupt;
    defer a.free(inst);
    var inst_fbs = std.io.fixedBufferStream(inst);
    var inst_reader = inst_fbs.reader().any();
    // We don't actually need these when zlib works :)
    _ = try readVarInt(&inst_reader);
    _ = try readVarInt(&inst_reader);

    const baseobj_offset = offset - srclen;
    const baseobj = try self.loadData(a, baseobj_offset, repo);
    defer a.free(baseobj.data);

    var buffer = std.ArrayList(u8).init(a);
    while (true) {
        _ = deltaInst(&inst_reader, buffer.writer(), baseobj.data) catch {
            break;
        };
    }
    return .{
        .header = baseobj.header,
        .data = try buffer.toOwnedSlice(),
    };
}

pub fn loadData(self: Pack, a: Allocator, offset: usize, repo: *const Repo) Error!PackedObject {
    var fbs = std.io.fixedBufferStream(self.pack[offset..]);
    var reader = fbs.reader().any();
    const h = parseObjHeader(&reader);

    return .{
        .header = h,
        .data = switch (h.kind) {
            .commit, .tree, .blob, .tag => loadBlob(a, &reader) catch return error.PackCorrupt,
            .ofs_delta => return try self.loadDelta(a, &reader, offset, repo),
            .ref_delta => return try self.loadRefDelta(a, &reader, offset, repo),
            .invalid => {
                std.debug.print("obj type ({}) not implemened\n", .{h.kind});
                @panic("not implemented");
            },
        },
    };
}

pub fn resolveObject(self: Pack, sha: SHA, a: Allocator, offset: usize, repo: *const Repo) !Object.Object {
    const resolved = try self.loadData(a, offset, repo);
    errdefer a.free(resolved.data);

    return switch (resolved.header.kind) {
        .blob => .{ .blob = .initOwned(sha, .{ 0, 0, 0, 0, 0, 0 }, resolved.data, resolved.data, resolved.data) },
        .tree => .{ .tree = try .initOwned(sha, a, resolved.data, resolved.data) },
        .commit => .{ .commit = try .initOwned(sha, a, resolved.data, resolved.data) },
        .tag => .{ .tag = try .initOwned(sha, resolved.data) },
        else => return error.IncompleteObject,
    };
}

pub fn raze(self: Pack) void {
    munmap(@alignCast(self.pack));
    munmap(@alignCast(self.idx));
}

const Error = Repo.Error;
const Repo = @import("Repo.zig");
const SHA = @import("SHA.zig");
const Object = @import("Object.zig");

const system = @import("../system.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const zlib = std.compress.zlib;
const MAP_TYPE = std.os.linux.MAP_TYPE;
const AnyReader = std.io.AnyReader;
const bufPrint = std.fmt.bufPrint;
const eql = std.mem.eql;
