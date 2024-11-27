const std = @import("std");

pub const Message = @import("types/message.zig");
pub const CommitMap = @import("types/commit-map.zig");
pub const Delta = @import("types/delta.zig");
pub const Diff = @import("types/diff.zig");
pub const Gist = @import("types/gist.zig");
pub const Issue = @import("types/issue.zig");
pub const Network = @import("types/network.zig");
pub const Read = @import("types/read.zig");
pub const Tags = @import("types/tags.zig");
pub const Thread = @import("types/thread.zig");
pub const User = @import("types/user.zig");
pub const Viewers = @import("types/viewers.zig");

pub const Writer = std.fs.File.Writer;

pub const Storage = std.fs.Dir;

pub fn init(dir: Storage) !void {
    inline for (.{
        Message,
        CommitMap,
        Delta,
        Diff,
        Gist,
        Issue,
        Network,
        Read,
        Thread,
        User,
    }) |inc| {
        try inc.initType(try dir.makeOpenPath(inc.TYPE_PREFIX, .{ .iterate = true }));
    }
}

pub fn raze() void {
    //Diff.raze();
}
