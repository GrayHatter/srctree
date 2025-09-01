name: []const u8,
url: ?[]const u8,
fetch: ?[]const u8,

const Remote = @This();

pub fn format(r: Remote, w: *Writer) !void {
    try w.print("Git.Remote: {s}", .{r.name});
}

pub fn formatDiff(r: Remote, w: *Writer) !void {
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
        try w.writeAll(printable);
        try w.writeAll(" [");
        try w.writeAll(r.name);
        try w.writeAll("]");
    }
}

pub fn formatLink(r: Remote, w: *Writer) !void {
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
            try w.writeAll("https://"); // LOL, sorry
            try w.writeAll(printable[0..i]);
            try w.writeAll("/");
            try w.writeAll(printable[i + 1 ..]);
        } else {
            try w.writeAll("https://"); // LOL, sorry
            try w.writeAll(printable);
        }
    }
}

/// Half supported alloc function
pub fn raze(r: Remote, a: std.mem.Allocator) void {
    a.free(r.name);
    if (r.url) |url| a.free(url);
    if (r.fetch) |fetch| a.free(fetch);
}

const std = @import("std");
const Writer = std.Io.Writer;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const indexOf = std.mem.indexOf;
