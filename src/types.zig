const std = @import("std");

pub const Comment = @import("types/comment.zig");
pub const CommitMap = @import("types/commit-note.zig");
pub const Delta = @import("types/delta.zig");
pub const Diff = @import("types/diff.zig");
pub const Issue = @import("types/issue.zig");
pub const Network = @import("types/network.zig");
pub const Thread = @import("types/thread.zig");
pub const User = @import("types/user.zig");

pub const Writer = std.fs.File.Writer;

pub const TypeStorage = std.fs.Dir;

pub fn init(dir: []const u8) !void {
    inline for (.{
        Comment,
        CommitMap,
        Delta,
        Diff,
        Issue,
        Network,
        Thread,
        User,
    }) |inc| {
        var buf: [2048]u8 = undefined;
        const filename = try std.fmt.bufPrint(&buf, inc.TYPE_PREFIX, .{dir});
        inc.datad = try std.fs.cwd().makeOpenPath(filename, .{ .iterate = true });
        try inc.initType();
    }
}

pub fn raze() void {
    //Diff.raze();
}
