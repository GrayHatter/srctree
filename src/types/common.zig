pub const State = struct {
    closed: bool = false,
    locked: bool = false,
    embargoed: bool = false,

    pub const default: State = .{
        .closed = false,
        .locked = false,
        .embargoed = false,
    };
};
