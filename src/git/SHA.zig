bin: Bin,
len: u5 = 20,

const SHA = @This();

pub const Bin = [20]u8;
pub const Hex = [40]u8;

pub fn init(sha: []const u8) SHA {
    if (sha.len == 20) {
        return .{ .bin = sha[0..20].* };
    } else if (sha.len == 40) {
        return .{ .bin = toBin(sha[0..40].*) };
    } else unreachable;
}

/// TODO return error, and validate it's actually hex
pub fn initPartial(sha: []const u8) SHA {
    var buf: Hex = @splat('f');
    for (buf[0..sha.len], sha[0..]) |*dst, src| dst.* = src;
    return .{
        .bin = toBin(buf),
        .len = @intCast(sha.len / 2),
    };
}

pub fn initCheck(sha: []const u8) !SHA {
    return switch (sha.len) {
        20 => .init(sha),
        40 => if (!ascii(sha)) return error.InvalidSha else .init(sha),
        else => error.InvalidSha,
    };
}

pub fn hex(sha: SHA) Hex {
    return toHex(sha.bin); //[0 .. sha.len * 2];
}

pub fn hexAlloc(sha: SHA, a: Allocator) !*Hex {
    const h = try a.create(Hex);
    h.* = toHex(sha.bin);
    return h;
}

pub fn toHex(sha: Bin) Hex {
    var hex_: Hex = undefined;
    _ = bufPrint(&hex_, "{x}", .{sha[0..]}) catch unreachable;
    return hex_;
}

pub fn toBin(sha: Hex) Bin {
    var bin: Bin = undefined;
    for (0..20) |i| {
        bin[i] = parseInt(u8, sha[i * 2 .. (i + 1) * 2], 16) catch unreachable;
    }
    return bin;
}

fn ascii(str: []const u8) bool {
    var lower: ?bool = null;
    for (str) |c| switch (c) {
        'a'...'f' => {
            if (lower) |l| if (!l) return false;
            lower = true;
        },
        'A'...'F' => {
            if (lower) |l| if (l) return false;
            lower = false;
        },
        '0'...'9' => {},
        else => return false,
    };
    return true;
}

pub fn eql(self: SHA, peer: SHA) bool {
    if (self.len != peer.len) return false;
    return mem.eql(u8, self.bin[0..self.len], peer.bin[0..self.len]);
}

pub fn startsWith(self: SHA, peer: SHA) bool {
    if (self.len < peer.len) return false;
    return mem.eql(u8, self.bin[0..peer.len], peer.bin[0..peer.len]);
}

pub fn formatHex(sha: SHA, w: *std.Io.Writer) !void {
    return try w.print("{x}", .{sha.bin[0..sha.len]});
}

pub fn formatBin(sha: SHA, w: *std.Io.Writer) !void {
    return try w.print("{any}", .{sha.bin[0..sha.len]});
}

test "hex tranlations" {
    const one = "370303630b3fc631a0cb3942860fb6f77446e9c1";
    var binbuf: [20]u8 = SHA.toBin(one.*);
    var hexbuf: [40]u8 = SHA.toHex(binbuf);

    try std.testing.expectEqualStrings(&binbuf, "\x37\x03\x03\x63\x0b\x3f\xc6\x31\xa0\xcb\x39\x42\x86\x0f\xb6\xf7\x74\x46\xe9\xc1");
    try std.testing.expectEqualStrings(&hexbuf, one);

    const two = "0000000000000000000000000000000000000000";
    binbuf = SHA.toBin(two.*);
    hexbuf = SHA.toHex(binbuf);

    try std.testing.expectEqualStrings(&binbuf, "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    try std.testing.expectEqualStrings(&hexbuf, two);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const bufPrint = std.fmt.bufPrint;
const parseInt = std.fmt.parseInt;
