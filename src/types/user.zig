const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();

pub const User = @This();

pub const TYPE_PREFIX = "{s}/users";
const USER_VERSION: usize = 0;

pub var datad: std.fs.Dir = undefined;
pub fn init(_: []const u8) !void {}
pub fn initType() !void {}

pub fn readVersioned(a: Allocator, file: std.fs.File) !User {
    var reader = file.reader();
    const ver: usize = try reader.readInt(usize, endian);
    switch (ver) {
        0 => {
            var local: User = undefined;
            if (try reader.read(&local.mtls_fp) != 40) return error.InvalidFile;
            local.username = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF);
            return User{
                .mtls_fp = local.mtls_fp,
                .username = local.username,
            };
        },
        else => return error.UnsupportedVersion,
    }
}

mtls_fp: [40]u8 = .{0} ** 40,
username: []const u8,

pub fn readFile(a: Allocator, file: std.fs.File) !User {
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
    return error.NotImplemnted;
}

pub fn findMTLSFingerprint(a: Allocator, fp: []const u8) !User {
    if (fp.len != 40) return error.InvalidFingerprint;
    var fpfbuf: [43]u8 = undefined;
    const fname = try std.fmt.bufPrint(&fpfbuf, "{s}.fp", .{fp});
    const file = datad.openFile(fname, .{}) catch return error.UserNotFound;
    return User.readFile(a, file);
}

pub fn open(a: Allocator, username: []const u8) !User {
    for (username) |c| if (!std.ascii.isLower(c)) return error.InvalidUsername;

    const ufile = datad.openFile(username, .{}) catch return error.UserNotFound;
    return try User.readFile(a, ufile);
}
