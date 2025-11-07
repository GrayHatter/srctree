pub const FileSys = struct {
    dir: []const u8 = "data/",
};

pub const Backing = union(enum) {
    filesys: FileSys,
};

pub const Options = struct {
    backing: Backing = .{ .filesys = .{} },
};

pub fn init(options: Options, io: std.Io) !void {
    switch (options.backing) {
        .filesys => |fs| try Types.init(
            try std.Io.Dir.cwd().makeOpenPath(io, fs.dir, .{ .iterate = true }),
            io,
        ),
    }
}

pub fn raze(io: std.Io) void {
    Types.raze(io);
}

const std = @import("std");
const Types = @import("types.zig");
