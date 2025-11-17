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

fn findFileSha(objs: Objects, sha: *SHA, io: Io) !Io.File {
    // TODO error on ambiguous ref
    var fb = [_]u8{0} ** 2048;
    const objdir = try bufPrint(&fb, "./{x}", .{sha.bin[0..1]});
    const dir = try objs.dir.openDir(io, objdir, .{ .iterate = true });
    defer dir.close(io);
    const old: std.fs.Dir = .adaptFromNewApi(dir);
    var itr = old.iterate();
    while (itr.next() catch null) |file| {
        if (startsWith(u8, file.name, sha.hex()[2 .. (sha.len - 1) * 2])) {
            return try dir.openFile(io, file.name, .{});
        }
    }
    return error.FileNotFound;
}

fn findFile(objs: Objects, sha: SHA, io: Io) !Io.File {
    if (sha.len == 20) {
        var fb = [_]u8{0} ** 2048;
        const grouped = try bufPrint(&fb, "./{s}/{s}", .{ sha.hex()[0..2], sha.hex()[2..] });
        const file = objs.dir.openFile(io, grouped, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const exact = try bufPrint(&fb, "./{s}", .{sha.hex()[0..]});
                return objs.dir.openFile(io, exact, .{}) catch |err2| switch (err2) {
                    error.FileNotFound => {
                        log.warn("unable to find commit '{s}'", .{sha.hex()[0..]});
                        return error.ObjectMissing;
                    },
                    else => return err2,
                };
            },
            else => return err,
        };
        return file;
    } else if (sha.len >= 6) {
        var new_sha = sha;
        return try objs.findFileSha(&new_sha, io);
    } else return error.InvalidSha;
}

fn loadFile(objs: Objects, sha: SHA, a: Allocator, io: Io) !Any {
    var file = try objs.findFile(sha, io);
    defer file.close(io);
    const stat = try file.stat(io);
    const compressed: []u8 = try a.alloc(u8, stat.size);
    defer a.free(compressed);
    var reader = file.reader(io, compressed);
    var z_b: [zlib.max_window_len * 2]u8 = undefined;
    var zl: std.compress.flate.Decompress = .init(&reader.interface, .zlib, &z_b);
    const data = try zl.reader.allocRemaining(a, .limited(0xffffff));
    errdefer a.free(data);
    if (indexOf(u8, data, "\x00")) |i| {
        const header = data[0..i];
        _ = header;
        const body = data[i + 1 ..];
        if (startsWith(u8, data, "blob ")) {
            return .{ .blob = .initOwned(sha, @splat(0xff), body, body, data) };
        } else if (startsWith(u8, data, "tree ")) {
            return .{ .tree = try .initOwned(sha, a, body, data) };
        } else if (startsWith(u8, data, "commit ")) {
            return .{ .commit = try .initOwned(sha, a, body, data) };
        } else if (startsWith(u8, data, "tag ")) {
            return .{ .tag = try .initOwned(sha, body) };
        }
    }
    return error.InvalidObject;
}
fn loadFromPacks(objs: Objects, sha: SHA, a: Allocator, io: Io) !?Any {
    for (objs.packs) |pack| {
        const offset = try pack.contains(sha) orelse continue;
        const fullsha = if (sha.len < 20) try pack.expandPrefix(sha) orelse unreachable else sha;
        return try pack.resolveObject(fullsha, offset, &objs, a, io);
    }
    return null;
}

pub fn loadObjectOrDelta(objs: Objects, sha: SHA, a: Allocator, io: Io) !union(enum) {
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

pub fn load(objs: Objects, sha: SHA, a: Allocator, io: Io) !Any {
    return try objs.loadFromPacks(sha, a, io) orelse try objs.loadFile(sha, a, io);
}

pub fn resolveSha(objs: Objects, sha: SHA, io: Io) !?SHA {
    if (sha.len == 20) return sha;
    if (sha.len < 3) return error.TooShort; // not supported

    for (objs.packs) |pack| {
        if (pack.expandPrefix(sha) catch |err| switch (err) {
            error.AmbiguousRef => return error.AmbiguousRef,
            else => return err,
        }) |s| {
            return s;
        }
    }
    var nsha = sha;

    var file = objs.findFileSha(&nsha, io) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    file.close(io);

    return null;
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
    const obj = try objs.load(SHA.init(lol), a, io);
    defer a.free(obj.commit.memory.?);
    try std.testing.expect(obj == .commit);
    if (false) std.debug.print("{}\n", .{obj});
}

test "hopefully a delta" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.fs.cwd();
    const dir = try cwd.openDir("repos/hastur/.git", .{});

    var objs: Objects = try .init(dir.adaptToNewApi(), io);
    try objs.initPacks(a, io);
    defer objs.raze(a, io);

    //var head = try objs.headCommit(a, io);
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
const indexOf = std.mem.indexOf;
const SHA = @import("SHA.zig");
const Pack = @import("pack.zig");
const Blob = @import("blob.zig");
const Tree = @import("tree.zig");
const Commit = @import("Commit.zig");
const Tag = @import("Tag.zig");
