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

    pub fn filename(f: File) [74]u8 {
        var output: [74]u8 = [_]u8{0} ** 64 ++ ".gist-file".*;
        var sha = Sha256.init(.{});
        sha.update(f.name);
        sha.update(f.blob);
        var bin: [32]u8 = undefined;
        sha.final(&bin);
        _ = bufPrint(&output, "{s}", .{hexLower(&bin)}) catch unreachable;
        return output;
    }

    const fRW = Types.readerWriter(File, .{ .name = &.{}, .blob = &.{} });

    const writerFn = fRW.write;
    const readerFn = fRW.read;
};

const RW = Types.readerWriter(Gist, .{});
const writerFn = RW.write;
const readerFn = RW.read;

pub fn new(owner: []const u8, files: []const File) ![64]u8 {
    var gist = Gist{
        .owner = owner,
        .created = std.time.timestamp(),
        .updated = std.time.timestamp(),
        .file_count = files.len,
        .files = files,
    };

    var buf: [64]u8 = undefined;
    const hash = gist.genHash();
    const filename = try bufPrint(&buf, "{s}", .{hexLower(hash)});
    try gist.commit();
    return filename[0..64].*;
}

pub fn open(a: Allocator, hash: [64]u8) !Gist {
    const data = try Types.loadData(.gist, a, hash ++ ".gist");
    return readerFn(data);
}

pub fn commit(gist: *Gist) !void {
    var buf: [69]u8 = undefined;
    const hash = gist.genHash();
    const filename = try bufPrint(&buf, "{s}.gist", .{hexLower(hash)});
    const file = try Types.commit(.gist, filename);
    defer file.close();
    var writer = file.writer();
    try writerFn(gist, &writer);

    for (gist.files) |gistfile| {
        const name = gistfile.filename();
        const data_file = try Types.commit(.gist_files, &name);
        defer data_file.close();
        var data_writer = data_file.writer();
        try File.writerFn(&gistfile, &data_writer);
        try writer.print("{s}\n", .{name[0..64]});
    }
    try writer.print("\n", .{});
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
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init(try tempdir.dir.makeOpenPath("datadir", .{ .iterate = true }));
    const mask: i64 = ~@as(i64, 0xffffff);

    var gist: Gist = .{
        .created = std.time.timestamp() & mask,
        .updated = std.time.timestamp() & mask,
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

    var out = std.ArrayList(u8).init(a);
    defer out.clearAndFree();
    var writer = out.writer();
    try writerFn(&gist, &writer);

    for (gist.files) |gistfile| {
        const name = gistfile.filename();
        const data_file = try Types.commit(.gist_files, &name);
        defer data_file.close();
        var data_writer = data_file.writer();
        try File.writerFn(&gistfile, &data_writer);
        try writer.print("{s}\n", .{name[0..64]});
    }
    try writer.print("\n", .{});

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
    try std.testing.expectEqualStrings(v0_text, out.items);

    try gist.commit();

    var buf: [69]u8 = undefined;
    const filename = try bufPrint(&buf, "{s}.gist", .{hexLower(&gist.hash)});
    const from_file = try Types.loadData(.gist, a, filename);
    defer a.free(from_file);

    try std.testing.expectEqualStrings(v0_text, from_file);
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const indexOf = std.mem.indexOf;
const hexLower = std.fmt.fmtSliceHexLower;
const bufPrint = std.fmt.bufPrint;
const endian = builtin.cpu.arch.endian();
const Sha256 = std.crypto.hash.sha2.Sha256;

const Types = @import("../types.zig");
