const std = @import("std");
const Allocator = std.mem.Allocator;
const build_mode = @import("builtin").mode;

// TODO rename this to... uhhh Map maybe?
pub const DataMap = @This();

pub const Pair = struct {
    name: []const u8,
    value: []const u8,
};

pub const Data = union(enum) {
    slice: []const u8,
    block: []DataMap,
    reader: std.io.AnyReader,
};

pub const HashMap = std.StringHashMap(Data);

ctx: HashMap,

pub fn Builder(comptime T: type) type {
    return struct {
        from: T,

        pub const Self = @This();

        pub fn init(from: T) Self {
            return .{
                .from = from,
            };
        }

        pub fn buildUnsanitized(self: Self, a: Allocator, ctx: *DataMap) !void {
            if (comptime @import("builtin").zig_version.minor >= 12) {
                if (std.meta.hasMethod(T, "contextBuilderUnsanitized")) {
                    return self.from.contextBuilderUnsanitized(a, ctx);
                }
            }

            inline for (std.meta.fields(T)) |field| {
                if (field.type == []const u8) {
                    try ctx.put(field.name, @field(self.from, field.name));
                }
            }
        }

        pub fn build(self: Self, a: Allocator, ctx: *DataMap) !void {
            if (comptime @import("builtin").zig_version.minor >= 12) {
                if (std.meta.hasMethod(T, "contextBuilder")) {
                    return self.from.contextBuilder(a, ctx);
                }
            }

            return self.buildUnsanitized(a, ctx);
        }
    };
}

pub fn init(a: Allocator) DataMap {
    return DataMap{
        .ctx = HashMap.init(a),
    };
}

pub fn initWith(a: Allocator, data: []const Pair) !DataMap {
    var ctx = DataMap.init(a);
    for (data) |d| {
        ctx.putSlice(d.name, d.value) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => unreachable,
        };
    }
    return ctx;
}

pub fn initBuildable(a: Allocator, buildable: anytype) !DataMap {
    var ctx = DataMap.init(a);
    const builder = buildable.builder();
    try builder.build(a, &ctx);
    return ctx;
}

pub fn raze(self: *DataMap) void {
    var itr = self.ctx.iterator();
    while (itr.next()) |*n| {
        switch (n.value_ptr.*) {
            .slice, .reader => continue,
            .block => |*block| for (block.*) |*b| b.raze(),
        }
    }
    self.ctx.deinit();
}

pub fn put(self: *DataMap, name: []const u8, value: Data) !void {
    try self.ctx.put(name, value);
}

pub fn get(self: DataMap, name: []const u8) ?Data {
    return self.ctx.get(name);
}

pub fn putSlice(self: *DataMap, name: []const u8, value: []const u8) !void {
    if (comptime build_mode == .Debug)
        if (!std.ascii.isUpper(name[0]))
            std.debug.print("Warning Template can't resolve {s}\n", .{name});
    try self.ctx.put(name, .{ .slice = value });
}

pub fn getSlice(self: DataMap, name: []const u8) ?[]const u8 {
    return switch (self.getNext(name) orelse return null) {
        .slice => |s| s,
        .block => unreachable,
        .reader => unreachable,
    };
}

/// Memory of block is managed by the caller. Calling raze will not free the
/// memory from within.
pub fn putBlock(self: *DataMap, name: []const u8, block: []DataMap) !void {
    try self.ctx.put(name, .{ .block = block });
}

pub fn getBlock(self: DataMap, name: []const u8) !?[]const DataMap {
    return switch (self.ctx.get(name) orelse return null) {
        // I'm sure this hack will live forever, I'm abusing With to be
        // an IF here, without actually implementing IF... sorry!
        //std.debug.print("Error: get [{s}] required Block, found slice\n", .{name});
        .slice, .reader => return error.NotABlock,
        .block => |b| b,
    };
}

pub fn putReader(self: *DataMap, name: []const u8, value: []const u8) !void {
    try self.putSlice(name, value);
}

pub fn getReader(self: DataMap, name: []const u8) ?std.io.AnyReader {
    switch (self.ctx.get(name) orelse return null) {
        .slice, .block => return error.NotAReader,
        .reader => |r| return r,
    }
    comptime unreachable;
}
