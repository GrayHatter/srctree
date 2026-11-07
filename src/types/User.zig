mtls_fingerprint_str: [40]u8 = @splat(0),
not_before: i64,
not_after: i64,
kind: Type = .user,
username: Types.VarString(256) = .{},

pub const User = @This();

pub const empty: User = .{
    .not_before = 0,
    .not_after = 0,
};

pub const Type = enum {
    user,
    system,
    remote,
};

pub const type_prefix = .users;
pub const type_version: usize = 1;

const TypeIo = Types.TypedIo(User);

pub fn typeIdent(u: User, w: *Io.Writer) !void {
    try w.print("{s}", .{u.mtls_fingerprint_str});
}

pub fn findMTLSFingerprint(fp: []const u8, a: Allocator, io: Io) !User {
    if (fp.len != 40) return error.InvalidFingerprint;
    var u: User = .empty;
    u.mtls_fingerprint_str = fp[0..40].*;
    var reader = try TypeIo.loadData(&u, a, io);
    defer reader.file.close(io);
    TypeIo.read(&u, &reader.interface);
    return u;
}

pub fn findByUsername(username: []const u8, a: Allocator, io: Io) !User {
    for (username) |c| if (!std.ascii.isLower(c)) return error.InvalidUsername;

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.user", .{username});
    var reader = try TypeIo.loadData(.users, filename, a, io);
    defer reader.file.close(io);
    return TypeIo.read.read(&reader);
}

pub fn new() !User {
    // TODO implement ln username -> fp
    return error.NotImplemnted;
}

pub fn commit(u: *const User, io: Io) !void {
    const file = try TypeIo.commit(u, io);

    var writer = file.writer();
    try TypeIo.write.write(&u, &writer);
}

test "reader/writer" {
    const a = std.testing.allocator;
    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();

    const this: User = .{
        .mtls_fingerprint_str = "ABCDEFGHIJKLMNOPQURSTUVWXYZabcdefghijklm".*,
        .username = .init("grayhatter"),
        .not_before = 0,
        .not_after = 999999999,
        .kind = .system,
    };
    try TypeIo.write(&this, &writer.writer);

    const expected =
        \\# users/1
        \\mtls_fingerprint_str: ABCDEFGHIJKLMNOPQURSTUVWXYZabcdefghijklm
        \\not_before: 0
        \\not_after: 999999999
        \\kind: system
        \\username: grayhatter
        \\
        \\
    ;
    const expected_var = try a.dupe(u8, expected);
    defer a.free(expected_var);

    try std.testing.expectEqualStrings(expected, writer.written());

    {
        var reader: Io.Reader = .fixed(writer.written());
        var read_this: User = .empty;
        TypeIo.read(&read_this, &reader);
        try std.testing.expectEqualStrings(this.username.slice(), read_this.username.slice());
        // lol sorry about this
        read_this.username = this.username;
        try std.testing.expectEqualDeep(this, read_this);
    }

    {
        var reader: Io.Reader = .fixed(expected_var);
        var from_expected_this: User = .empty;
        TypeIo.read(&from_expected_this, &reader);
        try std.testing.expectEqualStrings(this.username.slice(), from_expected_this.username.slice());
        // lol sorry about this
        from_expected_this.username = this.username;
        try std.testing.expectEqualDeep(this, from_expected_this);
    }
}

const std = @import("std");
const log = std.log.scoped(.srctypes_mtlsuser);
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const endian = builtin.cpu.arch.endian();
const bufPrint = std.fmt.bufPrint;

const Types = @import("../types.zig");
