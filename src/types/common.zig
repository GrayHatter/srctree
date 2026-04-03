pub const State = struct {
    closed: bool = false,
    draft: bool = false,
    embargoed: bool = false,
    locked: bool = false,
    removed: bool = false,

    pub const default: State = .{
        .closed = false,
        .draft = false,
        .embargoed = false,
        .locked = false,
        .removed = false,
    };

    /// Open is a special state
    pub fn isOpen(s: State) bool {
        return !s.closed and !s.locked and !s.draft and !s.removed;
    }
};
