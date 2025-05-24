pub const Ref = union(enum) {
    tag: Tag,
    branch: Branch,
    sha: SHA,
    missing: void,
};

pub const Tag = @import("Tag.zig");
pub const Branch = @import("Branch.zig");
pub const SHA = @import("SHA.zig");
