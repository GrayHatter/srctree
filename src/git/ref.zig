pub const Ref = union(enum) {
    tag: Tag,
    branch: Branch,
    sha: Sha,
    missing: void,
};

pub const Tag = @import("Tag.zig");
pub const Branch = @import("Branch.zig");
pub const Sha = @import("Sha.zig");
