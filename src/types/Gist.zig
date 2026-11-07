hash: Hash = @splat(0),
created: i64 = 0,
updated: i64 = 0,
owner: []const u8 = &.{},
file_count: usize = 0,
files: []File = &.{},

const Gist = @This();

const Hash = types.DefaultHash;

pub const type_prefix = .gist;
pub const type_version: usize = 0;

pub const File = struct {
    name: []const u8,
    created: i64,
    hash: Hash = @splat(0),
    blob: []const u8,

    pub const empty: File = .{ .name = &.{}, .blob = &.{} };

    pub const type_prefix = .gist_file;
    pub const type_version = 0;
    pub const type_skip_fields: [1][]const u8 = .{"blob"};

    const TypeIo = types.TypedIo(File);

    pub fn typeIdent(f: File, w: *Io.Writer) !void {
        try w.print("{x}", .{f.hash});
    }

    fn init(name: []const u8, blob: []const u8) !File {
        if (name.len == 0) return error.InvalidName;
        if (indexOf(u8, name, "\n") != null) return error.InvalidName;
        return .{
            .name = name,
            .blob = blob,
            .created = 0,
        };
    }

    pub fn new(name: []const u8, blob: []const u8, io: Io) !File {
        if (name.len == 0) return error.InvalidName;
        if (indexOf(u8, name, "\n") != null) return error.InvalidName;
        const f: File = .{
            .name = name,
            .blob = blob,
            .created = Io.Clock.real.now(io).toSeconds(),
        };
        try f.commit(io);
        return f;
    }

    pub fn open(file: *File, a: Allocator, io: Io) !void {
        var reader = try File.TypeIo.loadData(file, a, io);
        defer reader.file.close(io);

        file.* = File.readerFn(&reader);
        if (indexOf(u8, reader.buffer, file.name)) |idx| {
            file.blob = reader.buffer[idx + file.name.len + 6 ..];
        }
    }

    fn genHash(f: *File) void {
        var sha = Sha256.init(.{});
        sha.update(f.name);
        sha.update(f.blob);

        sha.update(&std.mem.toBytes(f.created));
        sha.final(&f.hash);
    }

    pub fn commit(file: *const File, io: Io) !void {
        var writer = try File.TypeIo.commitExtra(file, io);
        defer writer.file.close(io);
        var w_b: [2048]u8 = undefined;
        writer.interface.buffer = &w_b;

        try writer.interface.writeAll(file.blob);
        try writer.interface.flush();
    }
};

const TypeIo = types.TypedIo(Gist); //, "{s}.");

pub fn typeIdent(g: Gist, w: *Io.Writer) !void {
    try w.print("{x}", .{g.hash});
}

pub fn new(owner: []const u8, files: []File, io: Io) !Gist {
    var gist = Gist{
        .owner = owner,
        .created = Io.Clock.real.now(io).toSeconds(),
        .updated = Io.Clock.real.now(io).toSeconds(),
        .file_count = files.len,
        .files = files,
    };

    gist.genHash();
    try gist.commit(io);
    return gist;
}

pub fn open(hash: Hash, a: Allocator, io: Io) !Gist {
    var gist: Gist = .empty;
    gist.hash = hash;
    var reader = try TypeIo.loadDataReader(a, io);
    TypeIo.read(&gist, &reader);

    if (indexOf(u8, reader.interface.buffer, "\n\n")) |start| {
        std.debug.assert(std.mem.count(u8, reader.interface.buffer[start + 2 ..], "\n") == gist.file_count + 1);
        const gist_files = try a.alloc(File, gist.file_count);
        gist.files = gist_files;

        var itr = std.mem.splitScalar(u8, reader.interface.buffer[start + 2 ..], '\n');
        var next = itr.next();
        for (gist_files) |*file| {
            if (next == null) return error.InvalidGist;
            std.debug.assert(next.?.len == 64);
            try file.open(next.?[0..64].*, a, io);
            next = itr.next();
        }
    }
    return gist;
}

pub fn commit(gist: *const Gist, io: Io) !void {
    var writer = try TypeIo.commitExtra(gist, io);
    defer writer.file.close(io);
    var w_b: [2048]u8 = undefined;
    writer.interface.buffer = &w_b;

    for (gist.files) |file| {
        try file.commit(io);
        try writer.interface.print("{x}\n", .{&file.hash});
    }
    try writer.interface.flush();
}

pub fn genHash(gist: *Gist) void {
    for (gist.hash) |c| {
        if (c != 0) break;
    } else {
        var sha = Sha256.init(.{});
        sha.update(gist.owner);
        sha.update(std.mem.asBytes(&gist.created));
        for (gist.files) |file| {
            // TODO sanitize file.name
            sha.update(file.name);
            sha.update(file.blob);
        }
        sha.final(&gist.hash);
    }
}

test {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try types.init((try tempdir.dir.createDirPathOpen(io, "datadir", .{ .open_options = .{ .iterate = true } })), io);
    const mask: i64 = ~@as(i64, 0x7ffffff);

    var gist: Gist = .{
        .created = Io.Clock.now(.real, io).toSeconds() & mask,
        .updated = Io.Clock.now(.real, io).toSeconds() & mask,
        .owner = "user",
        .file_count = 3,
        .files = @constCast(&[_]File{
            .{ .name = "first.txt", .blob = "no text here\n\n\n\n", .created = 0 },
            .{ .name = "second.png", .blob = "no text here\n\n\n\n", .created = 0 },
            .{
                .name = "third.zig",
                .blob =
                \\const std = @import("std");
                \\pub fn main () !void {
                \\    return;
                \\}
                \\
                ,
                .created = 0,
            },
        }),
    };
    _ = gist.genHash();

    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try TypeIo.write(&gist, &writer.writer);

    for (gist.files) |*file| {
        file.genHash();
        var gf_writer = try File.TypeIo.commitExtra(file, io);
        defer gf_writer.file.close(io);
        var w_b: [2048]u8 = undefined;
        gf_writer.interface.buffer = &w_b;
        try File.TypeIo.write(file, &gf_writer.interface);
        try writer.writer.print("{x}\n", .{file.hash});
    }

    const v0_text =
        \\# gist/0
        \\hash: 2e89a49400feba5bccda228e1c7392946875360378afab8fe283ad26d8be4061
        \\created: 1744830464
        \\updated: 1744830464
        \\owner: user
        \\file_count: 3
        \\
        \\312bd76f48ab5bb20cda64974a351d8dbb2a66e4dc3c87bdeff8ddc44c879488
        \\712c5d25cdd635f68a870a2184433ceee9aaacb408395fb84612b3d1961ba5e5
        \\1b90d2209e8edbe3ba257505f509a4c1718890691eb46d9ac3e6649abe0fb77b
        \\
    ;
    try std.testing.expectEqualStrings(v0_text, writer.written());

    try gist.commit(io);

    const reader = try TypeIo.loadData(&gist, a, io);
    defer reader.file.close(io);
    defer a.free(reader.interface.buffer);

    try std.testing.expectEqualStrings(v0_text, reader.interface.buffer);
    //try std.testing.expectEqualDeep(gist, readerFn(&reader.interface));
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const indexOf = std.mem.indexOf;
const bufPrint = std.fmt.bufPrint;
const endian = builtin.cpu.arch.endian();
const Sha256 = std.crypto.hash.sha2.Sha256;

const types = @import("../types.zig");
