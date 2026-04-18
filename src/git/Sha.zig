hash: Hash,

const Sha = @This();

pub const Partial = struct {
    bytes: [31]u8,
    /// Unfortunately Git thinks returning 7 ascii is reasonable so this is hex len, or bin nibbles
    len: u8,
};

pub const Hash = union(enum) {
    sha1: Sha1,
    sha256: Sha256,
    partial: Partial,

    pub const zeros: Hash = .{ .sha1 = @splat(0) };
    pub const zeros265: Hash = .{ .sha256 = @splat(0) };

    pub const Sha1 = [20]u8;
    pub const Sha256 = [32]u8;

    pub fn fromText(t: Text) Hash {
        switch (t) {
            .sha1 => |txt| {
                var bin: Hash.Sha1 = undefined;
                for (0..20) |i| {
                    bin[i] = parseInt(u8, txt[i * 2 ..][0..2], 16) catch unreachable;
                }
                return .{ .sha1 = bin };
            },
            .sha256 => |txt| {
                var bin: Hash.Sha256 = undefined;
                for (0..32) |i| {
                    bin[i] = parseInt(u8, txt[i * 2 ..][0..2], 16) catch unreachable;
                }
                return .{ .sha256 = bin };
            },
        }
    }

    /// returns the valid bytes held by `Hash`
    pub fn bytes(h: *const Hash) []const u8 {
        return switch (h.*) {
            .sha1 => h.sha1[0..],
            .sha256 => h.sha256[0..],
            .partial => h.partial.bytes[0..h.partial.bytes.len],
        };
    }

    pub fn dupeStr(h: Hash, a: Allocator) ![]u8 {
        const t: Text = .fromBin(h);
        return try t.dupe(a);
    }

    pub fn fmtHex(h: Hash, w: *std.Io.Writer) !void {
        switch (h) {
            .sha1 => try w.print("{x}", .{h.sha1}),
            .sha256 => try w.print("{x}", .{h.sha256}),
            .partial => try w.print("{x}", .{h.partial.bytes[0..@divFloor(h.partial.len, 2)]}),
        }
    }

    pub fn format(t: Hash, w: *std.Io.Writer) !void {
        switch (t) {
            .sha1 => try w.print("{s}", .{t.sha1}),
            .sha256 => try w.print("{s}", .{t.sha256}),
            .partial => unreachable,
        }
    }
};

pub const Text = union(enum) {
    sha1: Sha1,
    sha256: Sha256,

    pub const zeros: Text = .{ .sha1 = @splat('0') };
    pub const zeros265: Text = .{ .sha256 = @splat('0') };

    pub const Sha1 = [40]u8;
    pub const Sha256 = [64]u8;

    pub fn slice(t: *const Text) []const u8 {
        return switch (t.*) {
            .sha1 => t.sha1[0..40],
            .sha256 => t.sha256[0..64],
        };
    }

    pub fn fromBin(h: Hash) Text {
        switch (h) {
            .sha1 => |bin| {
                var t: Text.Sha1 = undefined;
                _ = bufPrint(&t, "{x}", .{bin[0..]}) catch unreachable;
                return .{ .sha1 = t };
            },
            .sha256 => |bin| {
                var t: Text.Sha256 = undefined;
                _ = bufPrint(&t, "{x}", .{bin[0..]}) catch unreachable;
                return .{ .sha256 = t };
            },
            .partial => |bin| {
                var t: Text.Sha1 = @splat('0');
                _ = bufPrint(&t, "{x}", .{bin.bytes[0..@divFloor(bin.len, 2)]}) catch unreachable;
                return .{ .sha1 = t };
            },
        }
    }

    pub fn dupe(t: Text, a: Allocator) ![]u8 {
        return try a.dupe(u8, t.slice());
    }

    pub fn format(t: Text, w: *std.Io.Writer) !void {
        switch (t) {
            .sha1 => try w.print("{s}", .{t.sha1}),
            .sha256 => try w.print("{s}", .{t.sha256}),
        }
    }
};

pub const empty: Sha = .{ .hash = .{ .sha1 = @splat(0) } };
pub const zeros: Sha = .{ .hash = .{ .sha1 = @splat(0) } };
pub const sha2_empty: Sha = .{ .hash = .{ .sha256 = @splat(0) } };
pub const sha1_ff: Sha = .{ .hash = .{ .sha1 = @splat(0xff) } };
pub const sha2_ff: Sha = .{ .hash = .{ .sha256 = @splat(0xff) } };

pub fn init(sha: []const u8) Sha {
    return switch (sha.len) {
        20, 40 => init1(sha),
        32, 64 => init256(sha),
        else => initPartial(sha),
    };
}

pub fn init1(sha: []const u8) Sha {
    return switch (sha.len) {
        20 => .{ .hash = .{ .sha1 = sha[0..20].* } },
        40 => .{ .hash = .fromText(.{ .sha1 = sha[0..40].* }) },
        else => unreachable,
    };
}

pub fn init256(sha: []const u8) Sha {
    return switch (sha.len) {
        32 => .{ .hash = .{ .sha256 = sha[0..32].* } },
        64 => .{ .hash = .fromText(.{ .sha256 = sha[0..64].* }) },
        else => unreachable,
    };
}

/// TODO return error, and validate it's actually hex
pub fn initPartial(sha: []const u8) Sha {
    std.debug.assert(sha.len < 40);
    var txt: Text.Sha256 = @splat('0');
    @memcpy(txt[0..sha.len], sha);
    const bin: Hash = .fromText(.{ .sha256 = txt });
    return .{ .hash = .{
        .partial = .{
            .bytes = bin.sha256[0..31].*,
            .len = @intCast(sha.len),
        },
    } };
}

pub fn initCheck(sha: []const u8) !Sha {
    return switch (sha.len) {
        20 => .init(sha),
        40 => if (!ascii(sha)) return error.InvalidSha else .init(sha),
        else => error.InvalidSha,
    };
}

pub fn text(sha: Sha) Text {
    return .fromBin(sha.hash); //[0 .. sha.len * 2];
}

pub fn textAlloc(sha: Sha, a: Allocator) ![]const u8 {
    switch (sha.hash) {
        .sha1 => {
            const t: Text = .fromBin(sha.hash);
            return try a.dupe(u8, t.sha1[0..]);
        },
        .sha256 => {
            const t: Text = .fromBin(sha.hash);
            return try a.dupe(u8, t.sha256[0..]);
        },
        .partial => unreachable,
    }
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

pub fn eql(self: Sha, peer: Sha) bool {
    if (std.meta.activeTag(self.hash) != std.meta.activeTag(peer.hash)) return false;
    switch (self.hash) {
        .sha1 => return mem.eql(u8, &self.hash.sha1, &peer.hash.sha1),
        .sha256 => return mem.eql(u8, &self.hash.sha256, &peer.hash.sha256),
        .partial => if (self.hash.partial.len == peer.hash.partial.len) return mem.eql(
            u8,
            self.hash.partial.bytes[0..self.hash.partial.len],
            peer.hash.partial.bytes[0..self.hash.partial.len],
        ) else return false,
    }
}

pub fn startsWith(self: Sha, peer: Sha) bool {
    switch (self.hash) {
        .partial => {
            if (peer.hash != .partial) return false;
            if (self.hash.partial.len < peer.hash.partial.len) return false;
            return mem.startsWith(
                u8,
                self.hash.partial.bytes[0..],
                peer.hash.partial.bytes[0..peer.hash.partial.len],
            );
        },
        .sha1 => switch (peer.hash) {
            .sha1 => return self.eql(peer),
            .sha256 => return false,
            .partial => return mem.startsWith(
                u8,
                self.hash.sha1[0..],
                peer.hash.partial.bytes[0..peer.hash.partial.len],
            ),
        },
        .sha256 => switch (peer.hash) {
            .sha1 => return false,
            .sha256 => return self.eql(peer),
            .partial => return mem.startsWith(
                u8,
                self.hash.sha256[0..],
                peer.hash.partial.bytes[0..peer.hash.partial.len],
            ),
        },
    }
    return false;
}

pub fn fmtHex(sha: Sha, w: *std.Io.Writer) !void {
    return try w.print("{f}", .{std.fmt.alt(sha.hash, .fmtHex)});
}

pub fn fmtBin(sha: Sha, w: *std.Io.Writer) !void {
    return try w.print("{f}", .{sha.hash});
}

test init {
    const sha = Sha.init("7d4786ded56e1ee6cfe72c7986218e234961d03c");
    try std.testing.expectEqualDeep(Sha{
        .hash = .{
            .sha1 = .{
                0x7d, 0x47, 0x86, 0xde, 0xd5, 0x6e, 0x1e, 0xe6,
                0xcf, 0xe7, 0x2c, 0x79, 0x86, 0x21, 0x8e, 0x23,
                0x49, 0x61, 0xd0, 0x3c,
            },
        },
    }, sha);

    const sha256 = Sha.init("a3a36b2bcc01d330131aecd87a714fcf83e22f5315d0ef8cd0b4914403f9939b");
    try std.testing.expectEqualDeep(Sha{
        .hash = .{
            .sha256 = .{
                0xa3, 0xa3, 0x6b, 0x2b, 0xcc, 0x01, 0xd3, 0x30,
                0x13, 0x1a, 0xec, 0xd8, 0x7a, 0x71, 0x4f, 0xcf,
                0x83, 0xe2, 0x2f, 0x53, 0x15, 0xd0, 0xef, 0x8c,
                0xd0, 0xb4, 0x91, 0x44, 0x03, 0xf9, 0x93, 0x9b,
            },
        },
    }, sha256);
}

test initPartial {
    const half_sha: Sha = .initPartial("7d4786ded56e1ee6cfe7");
    try std.testing.expectEqualDeep(Sha{
        .hash = .{
            .partial = .{
                .bytes = .{
                    0x7d, 0x47, 0x86, 0xde, 0xd5, 0x6e, 0x1e, 0xe6, 0xcf, 0xe7,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00,
                },
                .len = 20,
            },
        },
    }, half_sha);

    const baby_sha = Sha.initPartial("7d");
    try std.testing.expectEqualDeep(Sha{
        .hash = .{
            .partial = .{
                .bytes = .{
                    0x7d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x00,
                },
                .len = 2,
            },
        },
    }, baby_sha);
}

test "hex tranlations" {
    const one = "370303630b3fc631a0cb3942860fb6f77446e9c1";
    var binbuf: [20]u8 = Sha.Hash.fromText(.{ .sha1 = one.* }).sha1;
    var hexbuf: [40]u8 = Sha.Text.fromBin(.{ .sha1 = binbuf }).sha1;

    try std.testing.expectEqualStrings(&binbuf, "\x37\x03\x03\x63\x0b\x3f\xc6\x31\xa0\xcb\x39\x42\x86\x0f\xb6\xf7\x74\x46\xe9\xc1");
    try std.testing.expectEqualStrings(&hexbuf, one);

    const two = "0000000000000000000000000000000000000000";
    binbuf = Sha.Hash.fromText(.{ .sha1 = two.* }).sha1;
    hexbuf = Sha.Text.fromBin(.{ .sha1 = binbuf }).sha1;

    try std.testing.expectEqualStrings(&binbuf, "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00");
    try std.testing.expectEqualStrings(&hexbuf, two);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const bufPrint = std.fmt.bufPrint;
const parseInt = std.fmt.parseInt;
