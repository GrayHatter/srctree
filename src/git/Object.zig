pub const Object = union(Kind) {
    blob: Blob,
    tree: Tree,
    commit: Commit,
    tag: Tag,

    pub const Kind = enum {
        blob,
        tree,
        commit,
        tag,
    };
};

const Blob = @import("blob.zig");
const Tree = @import("tree.zig");
const Commit = @import("Commit.zig");
const Tag = @import("Tag.zig");
