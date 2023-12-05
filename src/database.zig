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
        .filesys => try Types.init("data"),
    }
}

pub fn raze() void {
    Types.raze();
}
