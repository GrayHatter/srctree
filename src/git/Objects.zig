dir: Dir,
packs: []Pack,

const Objects = @This();

pub fn init(d: Dir, io: Io) !Objects {
    const dir: Dir = try d.openDir(io, "./objects", .{ .iterate = true });
    return .{ .dir = dir, .packs = &.{} };
}

pub fn initPacks(objs: *Objects, a: Allocator, io: Io) !void {
    var pack_dir = try objs.dir.openDir(io, "./pack", .{ .iterate = true });
    defer pack_dir.close(io);
    objs.packs = try Pack.initAllFromDir(pack_dir, a, io);
}

pub fn raze(objs: Objects, a: Allocator, io: Io) void {
    objs.dir.close(io);
    for (objs.packs) |pack| {
        pack.raze();
    }
    a.free(objs.packs);
}

fn findFileSha(objs: Objects, sha: *Sha, io: Io) LoadError!Io.File {
    // TODO error on ambiguous ref
    var fb = [_]u8{0} ** 2048;
    const byte: u8 = switch (sha.hash) {
        .sha1 => |sh| sh[0],
        .sha256 => |sh| sh[0],
        .partial => |pt| pt.bytes[0],
    };

    const objdir = bufPrint(&fb, "./{x}", .{byte}) catch unreachable;
    const dir = try objs.dir.openDir(io, objdir, .{ .iterate = true });
    defer dir.close(io);
    var itr = dir.iterate();
    const text = bufPrint(&fb, "{f}", .{std.fmt.alt(sha.*, .fmtHex)}) catch unreachable;

    while (itr.next(io) catch null) |file| {
        if (startsWith(u8, file.name, text[2..])) {
            sha.* = .init(bufPrint(&fb, "{x}{s}", .{ byte, file.name[0..] }) catch unreachable);
            return dir.openFile(io, file.name, .{}) catch return error.OtherFileSys;
        }
    }
    return error.FileNotFound;
}

fn findFile(objs: Objects, sha: Sha, io: Io) LoadError!Io.File {
    if (sha.hash == .partial and sha.hash.partial.len >= 6) {
        var new_sha = sha;
        return try objs.findFileSha(&new_sha, io);
    }
    const shatext: Sha.Text = sha.text();
    const text: []const u8 = switch (shatext) {
        .sha1 => |sh| &sh,
        .sha256 => |sh| &sh,
    };
    var fb = [_]u8{0} ** 2048;
    const grouped = bufPrint(&fb, "./{s}/{s}", .{ text[0..2], text[2..] }) catch unreachable;
    const file = objs.dir.openFile(io, grouped, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const exact = bufPrint(&fb, "./{s}", .{text[0..]}) catch unreachable;
            return objs.dir.openFile(io, exact, .{}) catch |err2| switch (err2) {
                error.FileNotFound => {
                    log.warn("unable to find commit '{s}'", .{text[0..]});
                    return error.ObjectMissing;
                },
                else => return error.OtherFileSys,
            };
        },
        else => return error.OtherFileSys,
    };
    return file;
}

pub const LoadError = error{
    Ambiguous,
    OtherFileSys,
    ObjectInvalid,
    ObjectMissing,
    ObjectCorrupt,
    OutOfMemory,
    ShaNotFound,
} || Dir.OpenError;

fn loadFile(objs: Objects, sha: Sha, a: Allocator, io: Io) LoadError!Any {
    var file = try objs.findFile(sha, io);
    defer file.close(io);
    const stat = file.stat(io) catch return error.OtherFileSys;
    const compressed: []u8 = try a.alloc(u8, stat.size);
    defer a.free(compressed);
    var reader = file.reader(io, compressed);
    var z_b: [zlib.max_window_len * 2]u8 = undefined;
    var zl: std.compress.flate.Decompress = .init(&reader.interface, .zlib, &z_b);

    if (zl.reader.takeSentinel(0)) |take| {
        if (startsWith(u8, take, "blob ")) {
            const data = zl.reader.allocRemaining(a, .limited(0xffffff)) catch unreachable;
            return .{ .blob = .init(sha, @splat(0xff), data, data) };
        } else if (startsWith(u8, take, "tree ")) {
            const data = zl.reader.allocRemaining(a, .limited(0xffffff)) catch unreachable;
            return .{ .tree = .init(sha, data) };
        } else if (startsWith(u8, take, "commit ")) {
            const data = zl.reader.allocRemaining(a, .limited(0xffffff)) catch unreachable;
            errdefer a.free(data);
            return .{ .commit = Commit.initOwned(sha, data) catch return error.ObjectCorrupt };
        } else if (startsWith(u8, take, "tag ")) {
            const data = zl.reader.allocRemaining(a, .limited(0xffffff)) catch unreachable;
            errdefer a.free(data);
            return .{ .tag = Tag.initOwned(sha, data) catch return error.ObjectCorrupt };
        } else {
            log.info("unknown object type \n{any}", .{take});
            return error.ObjectInvalid;
        }
    } else |_| return error.ObjectInvalid;
}

fn loadFromPacks(objs: Objects, sha: Sha, a: Allocator, io: Io) LoadError!?Any {
    for (objs.packs) |pack| {
        const offset = try pack.contains(sha) orelse continue;
        const fullsha = switch (sha.hash) {
            .partial => |p| try pack.expandPrefix(p),
            else => sha,
        };
        return pack.resolveOffset(fullsha, offset, &objs, a, io) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ObjectCorrupt => return error.ObjectCorrupt,
            error.ObjectMissing => error.ObjectMissing,
            error.ObjectInvalid => error.ObjectInvalid,
            error.DeltaRef, error.DeltaOffset => unreachable,
            error.PackCorrupt => unreachable,
            error.EndOfStream => unreachable,
            error.ReadFailed => unreachable,
            error.PackRef => unreachable,
            error.Ambiguous => unreachable,
        };
    }
    return null;
}

pub fn loadObjectOrDelta(objs: Objects, sha: Sha, a: Allocator, io: Io) !union(enum) {
    pack: Pack.PackedObject,
    file: Any,
} {
    for (objs.packs) |pack| {
        if (try pack.contains(sha)) |offset| {
            return .{ .pack = try pack.loadData(offset, &objs, a, io) };
        }
    }
    return .{ .file = try objs.loadFile(sha, a, io) };
}

pub fn load(objs: Objects, sha: Sha, a: Allocator, io: Io) !Any {
    return try objs.loadFromPacks(sha, a, io) orelse try objs.loadFile(sha, a, io);
}

pub fn resolveSha(objs: Objects, sha: Sha, io: Io) !Sha {
    if (sha.hash != .partial) return sha;
    if (sha.hash.partial.len < 6) return error.TooShort; // not supported

    for (objs.packs) |pack| if (pack.expandPrefix(sha.hash.partial)) |expanded| {
        return expanded;
    } else |err| switch (err) {
        error.ShaNotFound => continue,
        error.Ambiguous => return error.Ambiguous,
    };

    var nsha = sha;
    var file = objs.findFileSha(&nsha, io) catch |err| switch (err) {
        error.FileNotFound => return error.ShaNotFound,
        else => return err,
    };
    file.close(io);

    return nsha;
}

test "read pack" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    const dir = try cwd.openDir(io, "repos/hastur/.git", .{});
    var objs = try init(dir, io);
    try objs.initPacks(a, io);
    defer objs.raze(a, io);

    var lol: []u8 = "";

    for (objs.packs, 0..) |pack, pi| {
        for (0..@byteSwap(pack.idx_header.fanout[255])) |oi| {
            const hexy = pack.objnames[oi * 20 .. oi * 20 + 20];
            if (hexy[0] != 0xd2) continue;
            if (false) std.debug.print("{} {} -> {x}\n", .{ pi, oi, hexy });
            if (hexy[1] == 0xb4 and hexy[2] == 0xd1) {
                if (false) std.debug.print("{s} -> {}\n", .{ pack.name, pack.offsets[oi] });
                lol = hexy;
            }
        }
    }
    const obj = try objs.load(Sha.init(lol), a, io);
    defer a.free(obj.commit.bytes);
    try std.testing.expect(obj == .commit);
    if (false) std.debug.print("{}\n", .{obj});
}

test "hopefully a delta" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var cwd = Io.Dir.cwd();
    const dir = try cwd.openDir(io, "repos/hastur/.git", .{});

    var objs: Objects = try .init(dir, io);
    try objs.initPacks(a, io);
    defer objs.raze(a, io);

    //var head = try objs.HEAD(a, io);
    //defer head.raze();
    //if (false) std.debug.print("{}\n", .{head});

    //const obj = try objs.loadFromPacks(head.tree, a, io) orelse return error.UnableToLoadObject;
    //switch (obj) {
    //    .tree => |tree| tree.raze(),
    //    else => return error.NotATree,
    //}
    //if (false) std.debug.print("{}\n", .{obj.tree});
}

test {
    var fb = [_]u8{0} ** 2048;
    const objdir = try bufPrint(&fb, "./objects/{x}", .{([1]u8{0})[0..1]});
    try std.testing.expectEqualStrings("./objects/00", objdir);
}

pub const Any = union(Kind) {
    blob: Blob,
    tree: Tree,
    commit: Commit,
    tag: Tag,

    pub const Kind = enum {
        blob,
        tree,
        commit,
        tag,
    };
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const zlib = std.compress.flate;
const bufPrint = std.fmt.bufPrint;
const log = std.log.scoped(.git_objects);
const startsWith = std.mem.startsWith;
const findScalar = std.mem.findScalar;
const Sha = @import("Sha.zig");
const Pack = @import("Pack.zig");
const Blob = @import("blob.zig");
const Tree = @import("Tree.zig");
const Commit = @import("Commit.zig");
const Tag = @import("Tag.zig");
