pub const Kind = enum {
    blob,
    tree,
    commit,
    tag,
};
kind: Kind,
memory: []u8,
header: []u8,
body: []u8,
