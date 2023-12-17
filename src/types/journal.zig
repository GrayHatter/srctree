const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Journaling = @This();

pub const EvtComment = struct {};

pub const EventKind = enum(u8) {
    comment = 0x00,
};

pub const Events = union(EventKind) {
    comment: EvtComment,
};

pub const Journal = struct {
    username: []u8,
    mtls_fp: ?[]u8 = null,

    pub fn readFile(a: Allocator, username: []const u8, file: std.fs.File) !Journal {
        defer file.close();

        var fp: ?[]u8 = try a.alloc(u8, 40);
        errdefer if (fp) |ffp| a.free(ffp);
        var count = try file.read(fp.?);
        if (count != 40) {
            a.free(fp.?);
            fp = null;
        }
        return Journal{
            .username = try a.dupe(u8, username),
            .mtls_fp = fp,
        };
    }
};

var datad: std.fs.Dir = undefined;

pub fn init(dir: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}/users", .{dir});
    datad = try std.fs.cwd().openDir(filename, .{});
}

pub fn raze() void {
    datad.close();
}

pub fn new() !Journal {
    return error.NotImplemnted;
}

pub fn findMTLSFingerprint(a: Allocator, fp: []const u8) !Journal {
    if (fp.len != 40) return error.InvalidFingerprint;
    var idir = try datad.openIterableDir(".", .{});
    defer idir.close();
    var itr = idir.iterate();
    while (try itr.next()) |f| {
        if (f.kind != .file) continue;
        const file = try datad.openFile(f.name, .{});
        errdefer file.close();
        var ckb: [40]u8 = undefined;
        var count = try file.read(&ckb);
        if (count != 40) {
            file.close();
            continue;
        }
        if (std.mem.eql(u8, &ckb, fp)) {
            try file.seekTo(0);
            return try Journal.readFile(a, f.name, file);
        }
    }
    return error.UserNotFound;
}

pub fn open(a: Allocator, username: []const u8) !Journal {
    for (username) |c| if (!std.ascii.isLower(c)) return error.InvalidUsername;

    const ufile = datad.openFile(username, .{}) catch return error.UserNotFound;
    return try Journal.readFile(a, ufile);
}
