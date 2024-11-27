const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();

const Types = @import("../types.zig");

pub const User = @This();

pub const TYPE_PREFIX = "users";
const USER_VERSION: usize = 1;

var datad: std.fs.Dir = undefined;
pub fn init(_: []const u8) !void {}
pub fn initType(stor: Types.Storage) !void {
    datad = stor;
}

mtls_fp: [40]u8 = .{0} ** 40,
not_before: i64,
not_after: i64,
username: []const u8,

pub fn findMTLSFingerprint(a: Allocator, fp: []const u8) !User {
    if (fp.len != 40) return error.InvalidFingerprint;
    const file = try openFile(fp);
    return readFile(a, file);
}

pub fn open(a: Allocator, username: []const u8) !User {
    for (username) |c| if (!std.ascii.isLower(c)) return error.InvalidUsername;

    const ufile = try openFile(username);
    return try readFile(a, ufile);
}

pub fn commit(self: User) !User {
    const file = try openFile(self.mtls_fp);
    const w = file.writer().any();
    try self.writeOut(w);
}

fn readVersioned(a: Allocator, file: std.fs.File) !User {
    var reader = file.reader();
    const ver: usize = try reader.readInt(usize, endian);
    switch (ver) {
        0 => {
            return User{
                .mtls_fp = try reader.readBytesNoEof(40),
                .not_before = std.math.minInt(i64),
                .not_after = std.math.maxInt(i64),
                .username = try reader.readUntilDelimiterAlloc(a, 0, 0xFFF),
            };
        },
        else => return error.UnsupportedVersion,
    }
}

fn openFile(fp: []const u8) !std.fs.File {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.fp", .{fp});
    return try datad.createFile(filename, .{ .read = true, .truncate = false });
}

fn readFile(a: Allocator, file: std.fs.File) !User {
    defer file.close();
    return readVersioned(a, file);
}

pub fn raze(self: User, a: Allocator) void {
    a.free(self.username);
}

pub fn writeOut(_: User) !void {
    unreachable; // not implemented
}

pub fn new() !User {
    // TODO implement ln username -> fp
    return error.NotImplemnted;
}
