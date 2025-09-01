mtls_fp: [40]u8 = .{0} ** 40,
not_before: i64,
not_after: i64,
username: struct {
    buffer: [128]u8 = undefined,
    len: usize = 0,

    pub fn slice(un: @This()) []const u8 {
        return un.buffer[0..un.len];
    }
} = .{},

pub const User = @This();

pub const type_prefix = "users";
pub const type_version: usize = 1;

const typeio = Types.readerWriter(User, .{ .not_before = 0, .not_after = 0 });
const writerFn = typeio.write;
const readerFn = typeio.read;

pub fn findMTLSFingerprint(a: Allocator, fp: []const u8) !User {
    if (fp.len != 40) return error.InvalidFingerprint;
    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, "{s}.user", .{fp});
    const file = try Types.loadData(.users, a, filename);
    return readerFn(file);
}

pub fn open(a: Allocator, username: []const u8) !User {
    for (username) |c| if (!std.ascii.isLower(c)) return error.InvalidUsername;

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.user", .{username});
    const data = try Types.loadData(.users, a, filename);
    return readerFn(data);
}

pub fn new() !User {
    // TODO implement ln username -> fp
    return error.NotImplemnted;
}

pub fn commit(u: User) !void {
    var buf: [2048]u8 = undefined;
    const filename = try bufPrint(&buf, "{s}.user", .{&u.mtls_fp});
    const file = try Types.commit(.users, filename);
    defer file.close();

    var writer = file.writer();
    try writerFn(&u, &writer);
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();
const bufPrint = std.fmt.bufPrint;

const Types = @import("../types.zig");
