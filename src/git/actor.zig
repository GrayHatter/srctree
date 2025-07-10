const std = @import("std");

pub const Actor = @This();

name: []const u8,
email: []const u8,
timestr: []const u8,
tzstr: []const u8,
timestamp: i64 = 0,
/// TODO: This will not remain i64
tz: i64 = 0,

pub fn make(data: []const u8) !Actor {
    var itr = std.mem.splitBackwardsScalar(u8, data, ' ');
    const tzstr = itr.next() orelse return error.ActorParse;
    const epoch = itr.next() orelse return error.ActorParse;
    const epstart = itr.index orelse return error.ActorParse;
    const email = trimEmail(itr.next() orelse return error.ActorParse);
    const name = itr.rest();

    return .{
        .name = name,
        .email = email,
        .timestr = data[epstart..data.len],
        .tzstr = tzstr,
        .timestamp = std.fmt.parseInt(i64, epoch, 10) catch return error.ActorParse,
    };
}

pub fn trimEmail(str: []const u8) []const u8 {
    const start = if (std.mem.indexOfScalar(u8, str, '<')) |i| i + 1 else 0;
    const end = std.mem.indexOfScalar(u8, str, '>') orelse str.len;
    return str[start..end];
}

pub fn format(self: Actor, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
    try out.print("Actor{{ name {s}, email {s} time {} }}", .{ self.name, self.email, self.timestamp });
}
