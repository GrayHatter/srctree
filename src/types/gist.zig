hash: Types.DefaultHash = @splat(0),
created: i64 = 0,
updated: i64 = 0,
owner: []const u8 = &.{},
file_count: usize = 0,
files: []const File = &.{},

const Gist = @This();

pub const type_prefix = "gist";
pub const type_version: usize = 0;

pub const File = struct {
    pub const type_prefix = "gist-file";
    pub const type_version = 0;
    name: []const u8,
    blob: []const u8,

    pub fn init(name: []const u8, blob: []const u8) !File {
        if (name.len == 0) return error.InvalidName;
        if (indexOf(u8, name, "\n") != null) return error.InvalidName;
        return .{
            .name = name,
            .blob = blob,
        };
    }

    pub fn open(file: *File, name: [64]u8, a: Allocator, io: Io) !void {
        var reader = try Types.loadDataReader(.gist_files, name ++ ".gist-file", a, io);

        file.* = File.readerFn(&reader);
        if (indexOf(u8, reader.buffer, file.name)) |idx| {
            file.blob = reader.buffer[idx + file.name.len + 6 ..];
        }
    }

    pub fn commit(file: File, io: Io) ![64]u8 {
        const name = file.filename();
        const data_file = try Types.commit(.gist_files, &name, io);
        defer data_file.close();
        var w_b: [2048]u8 = undefined;
        var data_writer = data_file.writer(&w_b);
        try File.writerFn(&file, &data_writer.interface);
        return name[0..64].*;
    }

    pub fn filename(f: File) [74]u8 {
        var output: [74]u8 = [_]u8{0} ** 64 ++ ".gist-file".*;
        var sha = Sha256.init(.{});
        sha.update(f.name);
        sha.update(f.blob);
        var bin: [32]u8 = undefined;
        sha.final(&bin);
        _ = bufPrint(&output, "{x}", .{&bin}) catch unreachable;
        return output;
    }

    const fRW = Types.readerWriter(File, .{ .name = &.{}, .blob = &.{} });

    const writerFn = fRW.write;
    const readerFn = fRW.read;
};

const RW = Types.readerWriter(Gist, .{});
const writerFn = RW.write;
const readerFn = RW.read;

pub fn new(owner: []const u8, files: []const File, io: Io) ![64]u8 {
    var gist = Gist{
        .owner = owner,
        .created = (try Io.Clock.now(.real, io)).toSeconds(),
        .updated = (try Io.Clock.now(.real, io)).toSeconds(),
        .file_count = files.len,
        .files = files,
    };

    var buf: [64]u8 = undefined;
    const hash = gist.genHash();
    const filename = try bufPrint(&buf, "{x}", .{hash});
    try gist.commit(io);
    return filename[0..64].*;
}

pub fn open(hash: [64]u8, a: Allocator, io: Io) !Gist {
    var reader = try Types.loadDataReader(.gist, hash ++ ".gist", a, io);
    var gist = readerFn(&reader);

    if (indexOf(u8, reader.buffer, "\n\n")) |start| {
        std.debug.assert(std.mem.count(u8, reader.buffer[start + 2 ..], "\n") == gist.file_count + 1);
        const gist_files = try a.alloc(File, gist.file_count);
        gist.files = gist_files;

        var itr = std.mem.splitScalar(u8, reader.buffer[start + 2 ..], '\n');
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

pub fn commit(gist: *Gist, io: Io) !void {
    var buf: [69]u8 = undefined;
    const hash = gist.genHash();
    const filename = try bufPrint(&buf, "{x}.gist", .{hash});
    const file = try Types.commit(.gist, filename, io);
    defer file.close();
    var w_b: [2048]u8 = undefined;
    var writer = file.writer(&w_b);
    try writerFn(gist, &writer.interface);

    for (gist.files) |gistfile| {
        const f_name = try gistfile.commit(io);
        try writer.interface.print("{s}\n", .{f_name[0..64]});
    }
    try writer.interface.print("\n", .{});
    try writer.interface.flush();
}

pub fn genHash(gist: *Gist) *const Types.DefaultHash {
    var sha = Sha256.init(.{});
    sha.update(gist.owner);
    sha.update(std.mem.asBytes(&gist.created));
    for (gist.files) |file| {
        // TODO sanitize file.name
        sha.update(file.name);
        sha.update(file.blob);
    }
    sha.final(&gist.hash);
    return &gist.hash;
}

test {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init((try tempdir.dir.makeOpenPath("datadir", .{ .iterate = true })).adaptToNewApi(), io);
    const mask: i64 = ~@as(i64, 0x7ffffff);

    var gist: Gist = .{
        .created = (try Io.Clock.now(.real, io)).toSeconds() & mask,
        .updated = (try Io.Clock.now(.real, io)).toSeconds() & mask,
        .owner = "user",
        .file_count = 3,
        .files = &[_]File{
            .{ .name = "first.txt", .blob = "no text here\n\n\n\n" },
            .{ .name = "second.png", .blob = "no text here\n\n\n\n" },
            .{
                .name = "third.zig",
                .blob =
                \\const std = @import("std");
                \\pub fn main () !void {
                \\    return;
                \\}
                \\
                ,
            },
        },
    };
    _ = gist.genHash();

    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try writerFn(&gist, &writer.writer);

    for (gist.files) |gistfile| {
        const name = gistfile.filename();
        const data_file = try Types.commit(.gist_files, &name, io);
        defer data_file.close();
        var w_b: [2048]u8 = undefined;
        var data_writer = data_file.writer(&w_b);
        try File.writerFn(&gistfile, &data_writer.interface);
        try writer.writer.print("{s}\n", .{name[0..64]});
    }
    try writer.writer.print("\n", .{});

    const v0_text =
        \\# gist/0
        \\hash: 2e89a49400feba5bccda228e1c7392946875360378afab8fe283ad26d8be4061
        \\created: 1744830464
        \\updated: 1744830464
        \\owner: user
        \\file_count: 3
        \\
        \\2064fe14850af6a4c42cb24ce340a9e7cda60c937efe5545cd854d51396cc418
        \\6c049fefa69c6d3982e73a68bb74bac8cf9f583a108dbf8b678d2ae35b73989a
        \\7760e15c9f68c25848bfbad6d45c5ad870bfbea5a749e502bb2a6ee7a13b39d5
        \\
        \\
    ;
    try std.testing.expectEqualStrings(v0_text, writer.written());

    try gist.commit(io);

    var buf: [69]u8 = undefined;
    const filename = try bufPrint(&buf, "{x}.gist", .{&gist.hash});
    var reader = try Types.loadDataReader(.gist, filename, a, io);
    defer a.free(reader.buffer);

    try std.testing.expectEqualStrings(v0_text, reader.buffer);
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

const Types = @import("../types.zig");
