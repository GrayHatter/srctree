name: []u8,
sha: SHA,
object: []const u8,
type: TagType,
tagger: Actor,
message: []const u8,
signature: ?[]const u8,
//TODO raze
memory: ?[]u8 = null,
//signature: ?Commit.GPGSig,

const Tag = @This();

pub const TagType = enum {
    commit,
    lightweight,

    pub fn fromSlice(str: []const u8) ?TagType {
        inline for (std.meta.tags(TagType)) |t| {
            if (std.mem.eql(u8, @tagName(t), str)) return t;
        }
        return null;
    }
};

pub fn raze(tag: Tag, a: std.mem.Allocator) void {
    switch (tag.type) {
        .lightweight => a.free(tag.name),
        else => {},
    }
}

pub fn init(sha: SHA, data: []const u8) !Tag {
    return fromSlice(sha, data);
}

pub fn initOwned(sha: SHA, data: []u8) !Tag {
    var tag = try init(sha, data);
    tag.memory = data;
    return tag;
}

pub fn fromObject(obj: Object, name: []u8) !Tag {
    return switch (obj) {
        .tag => |tag| try .fromSlice(tag.sha, tag.memory.?),
        .commit => |cmt| try .lightTag(cmt.sha, name, cmt.memory orelse cmt.body),
        else => error.NotATag,
    };
}

pub fn fromSlice(sha: SHA, bblob: []const u8) !Tag {
    // sometimes, the slice will have a preamble
    var blob = bblob;
    if (indexOf(u8, bblob[0..20], "\x00")) |i| {
        std.debug.assert(startsWith(u8, bblob, "tag "));
        blob = bblob[i + 1 ..];
    }
    //std.debug.print("tag\n{s}\n{s}\n", .{ sha, bblob });
    if (startsWith(u8, blob, "tree ")) {
        // should be unreachable
        @panic("unreachable");
        // return try lightTag(sha, blob);
    }
    return try fullTag(sha, blob);
}

/// I don't like this implementation, but I can't be arsed... good luck
/// future me!
/// Dear past me... fuck you! dear future me... HA same!
/// Dear past mes... you both suck!
pub fn lightTag(sha: SHA, name: []u8, blob: []const u8) !Tag {
    var actor: ?Actor = null;
    if (indexOf(u8, blob, "committer ")) |i| {
        var act = blob[i + 10 ..];
        if (indexOf(u8, act, "\n")) |end| act = act[0..end];
        actor = Actor.make(act) catch return error.InvalidActor;
    } else return error.InvalidTag;

    return .{
        .name = name,
        .sha = sha,
        .object = sha.hex()[0..],
        .type = .lightweight,
        .tagger = actor orelse unreachable,
        .message = "",
        .signature = null,
    };
}

pub fn fullTag(sha: SHA, blob: []const u8) !Tag {
    var name: ?[]u8 = null;
    var object: ?[]const u8 = null;
    var ttype: ?TagType = null;
    var actor: ?Actor = null;
    var itr = splitScalar(u8, blob, '\n');
    while (itr.next()) |line| {
        if (startsWith(u8, line, "object ")) {
            object = line[7..];
        } else if (startsWith(u8, line, "type ")) {
            ttype = TagType.fromSlice(line[5..]);
        } else if (startsWith(u8, line, "tag ")) {
            name = @constCast(line[4..]);
        } else if (startsWith(u8, line, "tagger ")) {
            actor = Actor.make(line[7..]) catch return error.InvalidActor;
        } else if (line.len == 0) {
            break;
        }
    }

    var msg: []const u8 = blob[itr.index.?..];
    var sig: ?[]const u8 = null;
    const sigstart: usize = std.mem.indexOf(u8, msg, "-----BEGIN PGP SIGNATURE-----") orelse 0;
    msg = msg[0..sigstart];
    if (sigstart > 0) {
        sig = msg[0..];
    }

    return .{
        .name = name orelse return error.InvalidTagName,
        .sha = sha,
        .object = object orelse return error.InvalidReference,
        .type = ttype orelse return error.InvalidType,
        .tagger = actor orelse return error.InvalidActor,
        .message = msg,
        .signature = sig,
    };
}

test fromSlice {
    const blob =
        \\object 73751d1c0e9eaeaafbf38a938afd652d98ee9772
        \\type commit
        \\tag v0.7.3
        \\tagger Robin Linden <dev@robinlinden.eu> 1645477245 +0100
        \\
        \\Yet another bugfix release for 0.7.0, especially for Samsung phones.
        \\-----BEGIN PGP SIGNATURE-----
        \\
        \\iQIzBAABCAAdFiEEtwCP8SwHm/bm6hnRYBpgS35gV3YFAmIT/bYACgkQYBpgS35g
        \\V3bcww/+IQa+cSfRZkrGpTfHx+GzDVcW7R9FBxJ2vLicLB0yd2b3GgqBByEJCppo
        \\P0m2mb/rcFajcvJw9UmjUBMEljZSc1pW1/zioo9zRxt9g2zdVNxf1CoFwD/I9UbN
        \\oEM1KK+QyuqQ61Fbfz7kdpwOuaZ5UBe8/gH9TO+wURNNJE/PlsNCmengEtnERl+F
        \\J8FEJW0j1Offwdbw92WUvEVf6egH2N9NDqkhHM8Fy7+UwM4hJam7wclQODI19ZDI
        \\AKvH2vhLP+CVqvMiNlycTlDKqjka0pK4jOD4eu+2oeIzADH8kyMObhdFSdzscgEU
        \\ExAxwN2s5sD7Be1Z38gld9XRZ0f7JgZmdF+rkZqjF+tXcqxHIZtASWRD1cXLLwBc
        \\9b0/d626bZhKNYyIsvs1s0SHPBMNWCOGHV9oXi/Yncd7xoReGBFXrhhqub9ngmT4
        \\FksiZbyx3D6o22yyCU7roajLneL/JMKx+PmUxQxDdpqMyLZea3ETjFAKkAVnM0El
        \\GuKTlh/cxAdkz+WKKltVQNOfkc7rJvAnx81krggu354MDasg5EDjB7Nud/hQB+/s
        \\Dy/mr8QpGUoccHgUHTL7b7zmgIrTrq3NEkucMxKKoj9KRtt91w0OYPP4667gFKue
        \\+S4r2zj6UlFy7yODdWs8ijKwhSvMgJnUT6dnpGNCsJrc/F2O5ms=
        \\=t+5I
        \\-----END PGP SIGNATURE-----
        \\
    ;
    const t_msg = "Yet another bugfix release for 0.7.0, especially for Samsung phones.\n";
    const t = try fromSlice(SHA.init("c66fba80f3351a94432a662b1ecc55a21898f830"), blob);
    try std.testing.expectEqualStrings("v0.7.3", t.name);
    try std.testing.expectEqualStrings("73751d1c0e9eaeaafbf38a938afd652d98ee9772", t.object);
    try std.testing.expectEqual(TagType.commit, t.type);
    try std.testing.expectEqualStrings("Robin Linden", t.tagger.name);
    try std.testing.expectEqualStrings(t_msg, t.message);
}

const std = @import("std");
const indexOf = std.mem.indexOf;
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;
const SHA = @import("SHA.zig");
const Actor = @import("actor.zig");
const Object = @import("Object.zig").Object;
