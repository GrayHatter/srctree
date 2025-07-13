name: []const u8,
url: ?[]const u8,
fetch: ?[]const u8,

const Remote = @This();

pub fn format(r: Remote, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
    if (comptime eql(u8, fmt, "diff")) {
        if (r.url) |url| {
            var printable = url;
            if (startsWith(u8, printable, "https://")) {
                printable = printable[8..];
            }
            if (indexOf(u8, printable, "@")) |i| {
                printable = printable[i + 1 ..];
            }
            if (endsWith(u8, printable, ".git")) {
                printable = printable[0 .. printable.len - 4];
            }
            try out.writeAll(printable);
            try out.writeAll(" [");
            try out.writeAll(r.name);
            try out.writeAll("]");
        }
    } else if (comptime eql(u8, fmt, "link")) {
        if (r.url) |url| {
            var printable = url;
            if (startsWith(u8, printable, "https://")) {
                printable = printable[8..];
            }
            if (indexOf(u8, printable, "@")) |i| {
                printable = printable[i + 1 ..];
            }
            if (endsWith(u8, printable, ".git")) {
                printable = printable[0 .. printable.len - 4];
            }
            if (indexOf(u8, printable, ":")) |i| {
                try out.writeAll("https://"); // LOL, sorry
                try out.writeAll(printable[0..i]);
                try out.writeAll("/");
                try out.writeAll(printable[i + 1 ..]);
            } else {
                try out.writeAll("https://"); // LOL, sorry
                try out.writeAll(printable);
            }
        }
    } else try out.print("Git.Remote: {s}", .{r.name});
}

/// Half supported alloc function
pub fn raze(r: Remote, a: std.mem.Allocator) void {
    a.free(r.name);
    if (r.url) |url| a.free(url);
    if (r.fetch) |fetch| a.free(fetch);
}

const std = @import("std");
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const indexOf = std.mem.indexOf;
