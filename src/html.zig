pub const Attribute = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub const Element = struct {
    attrs: []Attribute,

    pub fn format() void {}
};
