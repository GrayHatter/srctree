const std = @import("std");
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;

pub const Remote = @This();

name: []const u8,
url: ?[]const u8,
fetch: ?[]const u8,

pub fn format(r: Remote, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
    if (std.mem.eql(u8, fmt, "diff")) {
        if (r.url) |url| {
            var printable = url;
            if (startsWith(u8, printable, "https://")) {
                printable = printable[8..];
            } else if (startsWith(u8, printable, "git@")) {
                printable = printable[4..];
            }
            if (endsWith(u8, printable, ".git")) {
                printable = printable[0 .. printable.len - 4];
            }
            try out.writeAll(printable);
            try out.writeAll(" [");
            try out.writeAll(r.name);
            try out.writeAll("]");
        }
    }
}

/// Half supported alloc function
pub fn raze(r: Remote, a: std.mem.Allocator) void {
    a.free(r.name);
    if (r.url) |url| a.free(url);
    if (r.fetch) |fetch| a.free(fetch);
}
