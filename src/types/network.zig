name: []u8,
location: []u8,
highlight: u8 = 0,

const Network = @This();

pub const type_prefix = "networks";
pub const type_version = 0;

const typeio = Types.readerWriter(Network, .{
    .name = &.{},
    .location = &.{},
});
const writerFn = typeio.write;
const readerFn = typeio.read;

pub fn new(name: []const u8, loc: []const u8, hl: bool) !Network {
    _ = name;
    _ = loc;
    _ = hl;
    unreachable;
    //if (!validName(name) or !validLocation(loc)) return error.InvalidNetwork;
    //var buf: [2048]u8 = undefined;
    //const filename = try std.fmt.bufPrint(&buf, "{s}.network", .{name});
    //const file = try datad.createFile(filename, .{});
    //var nw = Network{
    //    .name = name,
    //    .location = loc,
    //    .highlight = if (hl) 1 else 0,
    //    .file = file,
    //};
    //try nw.writeOut();
    //return nw;
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const Types = @import("../types.zig");
