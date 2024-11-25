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

test "directive For" {
    var a = std.testing.allocator;

    const blob =
        \\<div><For Loop><span><Name></span></For></div>
    ;

    const expected: []const u8 =
        \\<div><span>not that</span></div>
    ;

    const dbl_expected: []const u8 =
        \\<div><span>first</span><span>second</span></div>
    ;

    var t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = blob,
    };

    var ctx = DataMap.init(a);
    defer ctx.raze();
    var blocks: [1]DataMap = [1]DataMap{
        DataMap.init(a),
    };
    try blocks[0].putSlice("Name", "not that");
    // We have to raze because it will be over written
    defer blocks[0].raze();
    try ctx.putBlock("Loop", &blocks);

    const p = try t.page(ctx).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings(expected, p);

    // many
    var many_blocks: [2]DataMap = [_]DataMap{
        DataMap.init(a),
        DataMap.init(a),
    };
    // what... 2 is many

    try many_blocks[0].putSlice("Name", "first");
    try many_blocks[1].putSlice("Name", "second");

    try ctx.putBlock("Loop", &many_blocks);

    const dbl_page = try t.page(ctx).build(a);
    defer a.free(dbl_page);
    try std.testing.expectEqualStrings(dbl_expected, dbl_page);

    //many_blocks[0].raze();
    //many_blocks[1].raze();
}

test "directive For & For" {
    var a = std.testing.allocator;

    const blob =
        \\<div>
        \\  <For Loop>
        \\    <span><Name></span>
        \\    <For Numbers>
        \\      <Number>
        \\    </For>
        \\  </For>
        \\</div>
    ;

    const expected: []const u8 =
        \\<div>
        \\  <span>Alice</span>
        \\    A0
        \\    A1
        \\    A2
    ++ "\n    \n" ++
        \\  <span>Bob</span>
        \\    B0
        \\    B1
        \\    B2
    ++ "\n    \n  \n" ++
        \\</div>
    ;

    var t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = blob,
    };

    var ctx = DataMap.init(a);
    defer ctx.raze();
    var outer = [2]DataMap{
        DataMap.init(a),
        DataMap.init(a),
    };

    try outer[0].putSlice("Name", "Alice");
    //defer outer[0].raze();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const lput = "Number";

    var alice_inner: [3]DataMap = undefined;
    try outer[0].putBlock("Numbers", &alice_inner);
    for (0..3) |i| {
        alice_inner[i] = DataMap.init(a);
        try alice_inner[i].putSlice(
            lput,
            try std.fmt.allocPrint(aa, "A{}", .{i}),
        );
    }

    try outer[1].putSlice("Name", "Bob");
    //defer outer[1].raze();

    var bob_inner: [3]DataMap = undefined;
    try outer[1].putBlock("Numbers", &bob_inner);
    for (0..3) |i| {
        bob_inner[i] = DataMap.init(a);
        try bob_inner[i].putSlice(
            lput,
            try std.fmt.allocPrint(aa, "B{}", .{i}),
        );
    }

    try ctx.putBlock("Loop", &outer);

    const p = try t.page(ctx).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings(expected, p);
}
