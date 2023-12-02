pub const Comments = @import("types/comments.zig");
pub const Diffs = @import("types/diffs.zig");
pub const Issues = @import("types/issues.zig");

pub fn init(dir: []const u8) !void {
    try Comments.init(dir);
    try Issues.init(dir);
    try Diffs.init(dir);
}
