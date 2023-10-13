const std = @import("std");

const Allocator = std.mem.Allocator;

pub const HIndex = std.StringHashMap(Value);

const Value = struct {
    str: []const u8,
    next: ?*Value = null,
};

pub const Headers = @This();

alloc: Allocator,
index: HIndex,

pub fn init(a: Allocator) Headers {
    return .{
        .alloc = a,
        .index = HIndex.init(a),
    };
}

pub fn raze(h: *Headers) void {
    h.index.deinit(h.alloc);
    h.* = undefined;
}

/// TODO actually normalize to thing
/// TODO are we gonna normilize comptime?
fn normilize(name: []const u8) !void {
    if (name.len == 0) return;
}

pub fn add(h: *Headers, comptime name: []const u8, value: []const u8) !void {
    try normilize(name);
    var res = try h.index.getOrPut(name);
    if (res.found_existing) {
        res.value_ptr.* = Value{
            .str = value,
            .next = res.value_ptr,
        };
    } else {
        res.value_ptr.* = Value{
            .str = value,
        };
    }
}

pub fn format(h: Headers, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
    _ = h;
    _ = out;
    unreachable;
}

pub fn clearAndFree(h: *Headers) void {
    h.index.clearAndFree(h.alloc);
}
