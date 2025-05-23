bin: Bin,
hex: Hex,
partial: bool = false,
len: usize = 0,
binlen: usize = 0,

const SHA = @This();

pub const Bin = [20]u8;
pub const Hex = [40]u8;

pub fn init(sha: []const u8) SHA {
    if (sha.len == 20) {
        return .{
            .bin = sha[0..20].*,
            .hex = toHex(sha[0..20].*),
        };
    } else if (sha.len == 40) {
        return .{
            .bin = toBin(sha[0..40].*),
            .hex = sha[0..40].*,
        };
    } else unreachable;
}

/// TODO return error, and validate it's actually hex
pub fn initPartial(sha: []const u8) SHA {
    var buf: [40]u8 = ("0" ** 40).*;
    for (buf[0..sha.len], sha[0..]) |*dst, src| dst.* = src;
    return .{
        .bin = toBin(buf[0..40].*),
        .hex = buf[0..].*,
        .partial = true,
        .len = sha.len,
        .binlen = sha.len / 2,
    };
}

pub fn toHex(sha: Bin) Hex {
    var hex: Hex = undefined;
    _ = bufPrint(&hex, "{}", .{hexLower(sha[0..])}) catch unreachable;
    return hex;
}

pub fn toBin(sha: Hex) Bin {
    var bin: Bin = undefined;
    for (0..20) |i| {
        bin[i] = parseInt(u8, sha[i * 2 .. (i + 1) * 2], 16) catch unreachable;
    }
    return bin;
}

pub fn eql(self: SHA, peer: SHA) bool {
    if (self.partial == true) @panic("not implemented");
    if (self.partial != peer.partial) return false;
    return mem.eql(u8, self.bin[0..20], peer.bin[0..20]);
}

pub fn eqlIsh(self: SHA, peer: SHA) bool {
    if (self.partial == true) @panic("not implemented");
    if (peer.partial != true) return self.eql(peer);
    return mem.eql(u8, self.bin[0..peer.binlen], peer.bin[0..peer.binlen]);
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
const mem = std.mem;
const bufPrint = std.fmt.bufPrint;
const parseInt = std.fmt.parseInt;
const hexLower = std.fmt.fmtSliceHexLower;
