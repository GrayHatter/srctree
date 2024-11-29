const std = @import("std");

const Verse = @import("verse.zig");
const Route = @import("routes.zig");

pub fn fileOnDisk(ctx: *Verse) Route.Error!void {
    _ = ctx.uri.next(); // clear /static
    const fname = ctx.uri.next() orelse return error.Unrouteable;
    if (fname.len == 0) return error.Unrouteable;
    for (fname) |c| switch (c) {
        'A'...'Z', 'a'...'z', '-', '_', '.' => continue,
        else => return error.Abusive,
    };
    if (std.mem.indexOf(u8, fname, "..")) |_| return error.Abusive;

    const static = std.fs.cwd().openDir("static", .{}) catch return error.Unrouteable;
    const fdata = static.readFileAlloc(ctx.alloc, fname, 0xFFFFFF) catch return error.Unknown;

    ctx.response.start() catch return error.Unknown;
    ctx.response.writeAll(fdata) catch return error.Unknown;
    ctx.response.finish() catch return error.Unknown;
}
