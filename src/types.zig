pub const Comments = @import("types/comments.zig");
pub const CommitMap = @import("types/commit-notes.zig");
pub const Deltas = @import("types/deltas.zig");
pub const Diffs = @import("types/diffs.zig");
pub const Issues = @import("types/issues.zig");
pub const Networks = @import("types/users.zig");
pub const Threads = @import("types/threads.zig");
pub const Users = @import("types/users.zig");

pub fn init(dir: []const u8) !void {
    try Comments.init(dir);
    try CommitMap.init(dir);
    try Deltas.init(dir);
    try Diffs.init(dir);
    try Issues.init(dir);
    try Networks.init(dir);
    try Threads.init(dir);
    try Users.init(dir);
}

pub fn raze() void {
    Diffs.raze();
}
