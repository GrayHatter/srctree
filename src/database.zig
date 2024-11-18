const std = @import("std");

const Types = @import("types.zig");

pub const FileSys = struct {
    dir: []const u8 = "data/",
};

pub const Backing = union(enum) {
    filesys: FileSys,
};

pub const Options = struct {
    backing: Backing = .{ .filesys = .{} },
};

pub fn init(options: Options) !void {
    switch (options.backing) {
        .filesys => |fs| try Types.init(try std.fs.cwd().makeOpenPath(fs.dir, .{ .iterate = true })),
    }
}

pub fn raze() void {
    Types.raze();
}
