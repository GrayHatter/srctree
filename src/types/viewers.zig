const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();

pub const Viewers = @This();

pub const TYPE_PREFIX = "{s}/read";
const READ_VERSION: usize = 0;

pub var datad: std.fs.Dir = undefined;
pub fn init(_: []const u8) !void {}
pub fn initType() !void {}

pub fn readVersioned(a: Allocator, file: std.fs.File, _: [20]u8) !Viewers {
    var reader = file.reader();
    const ver: usize = try reader.readInt(usize, endian);
    switch (ver) {
        0 => {
            var local: Viewers = undefined;
            if (try reader.read(&local.src) != 20) return error.InvalidFile;
            local.username = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF);
            return Viewers{
                .src = local.src,
                .username = local.username,
                .time = try reader.readInt(i64, endian),
            };
        },
        else => return error.UnsupportedVersion,
    }
}

src: [20]u8 = .{0} ** 20,
viewers: []u8,
time: i64,

pub const Iterator = struct {
    index: usize = 0,
    blob: []const u8,

    pub fn init(blob: []const u8) Iterator {
        return .{
            .blob = blob,
        };
    }

    pub fn first(self: *Iterator) ?[]const u8 {
        self.index = 0;
        return self.next();
    }

    pub fn next(self: *Iterator) ?[]const u8 {
        if (self.index >= self.blob.len) return null;
        const next_i = std.mem.indexOf(u8, self.blob[self.index], self.index, "\n");
        defer self.index = next_i +| 1;
        return self.blob[self.index..next_i];
    }
};

pub fn users(self: Viewers) Iterator {
    return Iterator.init(self.viewers);
}

pub fn readFile(a: Allocator, file: std.fs.File) !Viewers {
    defer file.close();
    return readVersioned(a, file);
}

pub fn raze(self: Viewers, a: Allocator) void {
    a.free(self.username);
}

pub fn writeOut(_: Viewers) !void {
    unreachable; // not implemented
}

pub fn new() !Viewers {
    return error.NotImplemnted;
}

pub fn open(a: Allocator, src: [20]u8) !Viewers {
    for (src) |c| if (!std.ascii.isLower(c)) return error.InvalidSrc;

    const ufile = datad.openFile(src, .{}) catch return error.SrcNotFound;
    return try Viewers.readFile(a, ufile);
}
