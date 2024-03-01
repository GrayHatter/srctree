const std = @import("std");

const Allocator = std.mem.Allocator;

const HTML = @import("html.zig");

const DOM = @This();

alloc: Allocator,
elems: std.ArrayList(HTML.E),
parent: ?*DOM = null,
child: ?*DOM = null,
next: ?HTML.E = null,

pub fn new(a: Allocator) *DOM {
    const self = a.create(DOM) catch unreachable;
    self.* = DOM{
        .alloc = a,
        .elems = std.ArrayList(HTML.E).init(a),
    };
    return self;
}

pub fn open(self: *DOM, elem: HTML.E) *DOM {
    if (self.child) |_| @panic("DOM Already Open");
    self.child = new(self.alloc);
    self.child.?.parent = self;
    self.child.?.next = elem;
    return self.child.?;
}

pub fn pushSlice(self: *DOM, elems: []HTML.E) void {
    for (elems) |elem| self.push(elem);
}

pub fn push(self: *DOM, elem: HTML.E) void {
    self.elems.append(elem) catch unreachable;
}

pub fn dupe(self: *DOM, elem: HTML.E) void {
    self.elems.append(HTML.E{
        .name = elem.name,
        .text = elem.text,
        .children = if (elem.children) |c| self.alloc.dupe(HTML.E, c) catch null else null,
        .attrs = if (elem.attrs) |a| self.alloc.dupe(HTML.Attribute, a) catch null else null,
    }) catch unreachable;
}

pub fn close(self: *DOM) *DOM {
    if (self.parent) |p| {
        self.next.?.children = self.elems.toOwnedSlice() catch unreachable;
        if (self.next.?.attrs) |attr| {
            self.next.?.attrs = self.alloc.dupe(HTML.Attribute, attr) catch unreachable;
        }
        p.push(self.next.?);
        p.child = null;
        defer self.alloc.destroy(self);
        return p;
    } else @panic("DOM ISN'T OPEN");
    unreachable;
}

pub fn done(self: *DOM) []HTML.E {
    if (self.child) |_| @panic("INVALID STATE DOM STILL HAS OPEN CHILDREN");
    defer self.alloc.destroy(self);
    return self.elems.toOwnedSlice() catch unreachable;
}

test "basic" {
    const a = std.testing.allocator;
    var dom = new(a);
    try std.testing.expect(dom.child == null);
    _ = dom.done();
}

test "open close" {
    var a = std.testing.allocator;
    var dom = new(a);
    try std.testing.expect(dom.child == null);

    var new_dom = dom.open(HTML.div(null, null));
    try std.testing.expect(new_dom.child == null);
    try std.testing.expect(dom.child == new_dom);
    const closed = new_dom.close();
    try std.testing.expect(dom == closed);
    try std.testing.expect(dom.child == null);

    a.free(dom.done());
}
