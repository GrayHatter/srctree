pack: []u8,
idx: []u8,
format: enum { sha1, sha256 } = .sha1,
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
pub fn init(dir: Io.Dir, name: []const u8, io: Io) !Pack {
    if (name.len > 70) return error.UnsupportedPackFormat;
    var filename: [100]u8 = undefined;
    const ifd = try dir.openFile(io, try bufPrint(&filename, "{s}.idx", .{name}), .{});
    defer ifd.close(io);
    const pfd = try dir.openFile(io, try bufPrint(&filename, "{s}.pack", .{name}), .{});
    defer pfd.close(io);
    var pack = Pack{
        .pack = try mmap(pfd, io),
        .idx = try mmap(ifd, io),
        .format = if (name.len < 60) .sha1 else .sha256,
    };
    try pack.prepare();
    return pack;
}

pub fn initAllFromDir(dir: Io.Dir, a: Allocator, io: Io) ![]Pack {
    var itr = dir.iterate();
    var packs: ArrayList(Pack) = try .initCapacity(a, 4);
    while (try itr.next(io)) |file| {
        if (!endsWith(u8, file.name, ".idx")) continue;
        try packs.append(a, try .init(dir, file.name[0 .. file.name.len - 4], io));
    }
    return try packs.toOwnedSlice(a);
}

fn prepare(self: *Pack) !void {
    try self.prepareIdx();
    try self.preparePack();
}

fn prepareIdx(self: *Pack) !void {
    return if (self.format == .sha1)
        self.prepareIdxWidth(20)
    else
        self.prepareIdxWidth(32);
}

fn prepareIdxWidth(self: *Pack, comptime width: u8) !void {
    self.idx_header = @ptrCast(@alignCast(self.idx.ptr));
    const count = @byteSwap(self.idx_header.fanout[255]);
    self.objnames = self.idx[258 * 4 ..][0 .. width * count];
    self.crc.ptr = @ptrCast(@alignCast(self.idx[258 * 4 + width * count ..].ptr));
    self.crc.len = count;
    self.offsets.ptr = @ptrCast(@alignCast(self.idx[258 * 4 + (width + 4) * count ..].ptr));
    self.offsets.len = count;

    self.hugeoffsets = null;
}

fn preparePack(self: *Pack) !void {
    self.idx_header = @ptrCast(@alignCast(self.idx.ptr));
}

fn mmap(f: Io.File, io: Io) ![]u8 {
    const stats = try f.stat(io);
    return system.mmap(f.handle, stats.size, .{});
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

fn orderSha(lhs: []const u8, rhs: []const u8) std.math.Order {
    for (0..@min(lhs.len, rhs.len)) |i|
        if (lhs[i] != rhs[i]) return if (lhs[i] < rhs[i]) .lt else .gt;
    return .eq;
}

pub fn contains(pack: Pack, sha: Sha) !?u32 {
    switch (sha.hash) {
        .sha1 => return pack.containsWidth(20, sha),
        .sha256 => return pack.containsWidth(32, sha),
        .partial => if (pack.format == .sha1)
            return pack.containsWidth(20, sha)
        else
            return pack.containsWidth(32, sha),
    }
}

pub fn containsWidth(self: Pack, comptime width: u8, sha: Sha) !?u32 {
    const shabin: []const u8 = switch (sha.hash) {
        .sha1 => &sha.hash.sha1,
        .sha256 => &sha.hash.sha256,
        .partial => sha.hash.partial.bytes[0..@divFloor(sha.hash.partial.len, 2)],
    };
    const count: usize = self.fanOutCount(shabin[0]);
    if (count == 0) return null;

    const start: usize = if (shabin[0] > 0) self.fanOut(shabin[0] - 1) else 0;

    const objnames_ptr: [*][width]u8 = @ptrCast(self.objnames[start * width ..][0 .. count * width]);
    const objnames = objnames_ptr[0..count];

    var left: usize = 0;
    var right: usize = objnames.len;
    //var b_idx: usize = 0;
    var found: ?usize = null;

    while (left < right) {
        const mid = left + (right - left) / 2;

        switch (orderSha(shabin, objnames[mid][0..width])) {
            .eq => {
                found = mid;
                break;
            },
            .gt => left = mid + 1,
            .lt => right = mid,
        }
    }

    if (found) |f| {
        if (objnames.len > f + 1 and startsWith(u8, objnames[f + 1][0..width], shabin)) {
            return error.AmbiguousRef;
        }
        if (f > 0 and startsWith(u8, objnames[f - 1][0..width], shabin)) {
            return error.AmbiguousRef;
        }
        return @byteSwap(self.offsets[f + start]);
    }

    return null;
}

pub fn expandPrefix(self: Pack, partial_sha: Sha.Partial) error{AmbiguousRef}!?Sha {
    const len: usize = @divFloor(partial_sha.len, 2);
    const partial: []const u8 = partial_sha.bytes[0..len];
    const count: usize = self.fanOutCount(partial[0]);
    if (count == 0) return null;

    const start: usize = if (partial[0] > 0) self.fanOut(partial[0] - 1) else 0;

    const objnames_ptr: [*][20]u8 = @ptrCast(self.objnames[start * 20 ..][0 .. count * 20]);
    const objnames = objnames_ptr[0..count];

    var left: usize = 0;
    var right: usize = objnames.len;
    var found: ?usize = null;

    while (left < right) {
        const mid = left + (right - left) / 2;

        switch (orderSha(partial, objnames[mid][0..len])) {
            .eq => {
                found = mid;
                break;
            },
            .gt => left = mid + 1,
            .lt => right = mid,
        }
    }

    if (found) |f| {
        if (objnames.len > f + 1 and startsWith(u8, &objnames[f + 1], partial)) {
            return error.AmbiguousRef;
        }
        if (f > 1 and startsWith(u8, &objnames[f - 1], partial)) {
            return error.AmbiguousRef;
        }
        return Sha.init(objnames[f][0..20]);
    }

    return null;
}

pub fn getReaderOffset(self: Pack, offset: u32) !Reader {
    if (offset > self.pack.len) return error.WTF;
    return self.pack[offset];
}

fn parseObjHeader(reader: *Reader) PackedObject.Header {
    var byte: usize = 0;
    byte = reader.takeByte() catch unreachable;
    var h = PackedObject.Header{
        .size = byte & 0b1111,
        .kind = @enumFromInt((byte & 0b01110000) >> 4),
    };
    var cont: bool = byte & 0x80 != 0;
    var shift: u6 = 4;
    while (cont) {
        byte = reader.takeByte() catch unreachable;
        h.size |= (byte << shift);
        shift += 7;
        cont = byte >= 0x80;
    }
    return h;
}

fn loadBlob(reader: *Reader, a: Allocator, _: Io) ![]u8 {
    var z_b: [zlib.max_window_len]u8 = undefined;
    var zl: std.compress.flate.Decompress = .init(reader, .zlib, &z_b);
    return try zl.reader.allocRemaining(a, .limited(0xffffff));
}

fn readVarInt(reader: *Reader) !usize {
    var byte: usize = try reader.takeByte();
    var base: usize = byte & 0x7F;
    while (byte >= 0x80) {
        base += 1;
        byte = try reader.takeByte();
        base = (base << 7) + (byte & 0x7F);
    }
    //std.debug.print("varint = {}\n", .{base});
    return base;
}

fn deltaInst(reader: *Reader, writer: *Writer, base: []const u8) !usize {
    const readb: usize = try reader.takeByte();
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
        if (readb & 1 != 0) offs |= @as(usize, try reader.takeByte()) << 0;
        if (readb & 2 != 0) offs |= @as(usize, try reader.takeByte()) << 8;
        if (readb & 4 != 0) offs |= @as(usize, try reader.takeByte()) << 16;
        if (readb & 8 != 0) offs |= @as(usize, try reader.takeByte()) << 24;
        //std.debug.print("    offs: {:12} {b:0>32} \n", .{ offs, offs });
        var size: usize = 0;
        if (readb & 16 != 0) size |= @as(usize, try reader.takeByte()) << 0;
        if (readb & 32 != 0) size |= @as(usize, try reader.takeByte()) << 8;
        if (readb & 64 != 0) size |= @as(usize, try reader.takeByte()) << 16;

        if (size == 0) size = 0x10000;
        //std.debug.print("    size: {:12}         {b:0>24} \n", .{ size, size });
        //std.debug.print("COPY {: >4} {: >4}\n", .{ offs, size });
        if (size != try writer.write(base[offs..][0..size]))
            @panic("write didn't not fail");
        return size;
    } else {
        _ = try writer.write(try reader.take(readb));
        //std.debug.print("INSERT {} \n", .{readb});
        return readb;
    }
}

fn loadRefDelta(_: Pack, reader: *Reader, _: usize, objs: *const Objects, a: Allocator, io: Io) Error!PackedObject {
    var buf: [20]u8 = (try reader.takeArray(20)).*;
    const sha = Sha.init(buf[0..]);

    const basefree: []u8, const basedata: []const u8, const basetype: PackedObjectTypes =
        switch (objs.loadObjectOrDelta(sha, a, io) catch return error.ObjectMissing) {
            .pack => |pk| .{ pk.data, pk.data, pk.header.kind },
            .file => |fdata| switch (fdata) {
                .blob => |b| .{ b.memory.?, b.data.?, .blob },
                .tree => |t| .{ t.memory.?, t.blob, .tree },
                .commit => |c| .{ c.memory.?, c.body, .commit },
                .tag => |t| .{ t.memory.?, t.memory.?, .tag },
            },
        };
    defer a.free(basefree);

    var z_b: [zlib.max_window_len]u8 = undefined;
    var zl: Decompress = .init(reader, .zlib, &z_b);
    // We don't actually need these when zlib works :)
    _ = try readVarInt(&zl.reader);
    _ = try readVarInt(&zl.reader);
    var buffer: Writer.Allocating = .init(a);
    while (true) _ = deltaInst(&zl.reader, &buffer.writer, basedata) catch break;
    return .{
        .header = .{ .size = 0, .kind = basetype },
        .data = try buffer.toOwnedSlice(),
    };
}

fn loadDelta(self: Pack, reader: *Reader, offset: usize, objs: *const Objects, a: Allocator, io: Io) Error!PackedObject {
    // fd pos is offset + 2-ish because of the header read
    const srclen = try readVarInt(reader);

    var z_b: [zlib.max_window_len]u8 = undefined;
    var zl: Decompress = .init(reader, .zlib, &z_b);
    // We don't actually need these when zlib works :)
    _ = try readVarInt(&zl.reader);
    _ = try readVarInt(&zl.reader);

    const baseobj_offset = offset - srclen;
    const baseobj = try self.loadData(baseobj_offset, objs, a, io);
    defer a.free(baseobj.data);

    var buffer: Writer.Allocating = .init(a);
    while (true) _ = deltaInst(&zl.reader, &buffer.writer, baseobj.data) catch break;
    return .{
        .header = baseobj.header,
        .data = try buffer.toOwnedSlice(),
    };
}

pub fn loadData(self: Pack, offset: usize, objs: *const Objects, a: Allocator, io: Io) Error!PackedObject {
    var reader = std.Io.Reader.fixed(self.pack[offset..]);
    const h = parseObjHeader(&reader);

    return .{
        .header = h,
        .data = switch (h.kind) {
            .commit, .tree, .blob, .tag => loadBlob(&reader, a, io) catch return error.PackCorrupt,
            .ofs_delta => return try self.loadDelta(&reader, offset, objs, a, io),
            .ref_delta => return try self.loadRefDelta(&reader, offset, objs, a, io),
            .invalid => {
                std.debug.print("obj type ({}) not implemened\n", .{h.kind});
                @panic("not implemented");
            },
        },
    };
}

pub fn resolveObject(self: Pack, sha: Sha, offset: usize, objs: *const Objects, a: Allocator, io: Io) !Objects.Any {
    const resolved = try self.loadData(offset, objs, a, io);
    errdefer a.free(resolved.data);

    return switch (resolved.header.kind) {
        .blob => .{ .blob = .initOwned(sha, .{ 0, 0, 0, 0, 0, 0 }, resolved.data, resolved.data, resolved.data) },
        .tree => .{ .tree = try .initOwned(sha, a, resolved.data, resolved.data) },
        .commit => .{ .commit = try .initOwned(sha, resolved.data, resolved.data) },
        .tag => .{ .tag = try .initOwned(sha, resolved.data) },
        else => return error.IncompleteObject,
    };
}

pub fn raze(self: Pack) void {
    munmap(@alignCast(self.pack));
    munmap(@alignCast(self.idx));
}

pub const Error = Reader.Error || error{
    OutOfMemory,
    PackCorrupt,
    PackRef,
    AmbiguousRef,
    ObjectMissing,
};

const Sha = @import("Sha.zig");
const Objects = @import("Objects.zig");

const system = @import("../system.zig");

const std = @import("std");
const Io = std.Io;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const zlib = std.compress.flate;
const MAP_TYPE = std.os.linux.MAP_TYPE;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const bufPrint = std.fmt.bufPrint;
const eql = std.mem.eql;
const endsWith = std.mem.endsWith;
const startsWith = std.mem.startsWith;
const Decompress = std.compress.flate.Decompress;
