const E = @import("../html.zig").E;
const Attr = @import("../html.zig").Attr;

const element = @import("../html.zig").element;

pub fn repo() E {
    return element("repo", null, null);
}

pub fn diff() E {
    return element("diff", null, null);
}

pub fn patch() E {
    return element("patch", null, null);
}

pub fn commit(c: anytype, attr: ?[]const Attr) E {
    return element("commit", c, attr);
}
