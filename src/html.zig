const std = @import("std");

var _alloc: std.mem.Allocator = undefined;
// TODO areana allocator with deinit

pub const Attribute = struct {
    key: []const u8,
    value: ?[]const u8,

    pub fn format(self: Element, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        if (self.value) |value| {
            try std.fmt.format(out, " {s}=\"{}\"", .{ self.key, value });
        } else {
            try std.fmt.format(out, " {s}", .{self.key});
        }
    }
};

pub const Element = struct {
    name: []const u8,
    attrs: []const Attribute,
    children: []const Element,

    pub fn format(self: Element, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        if (self.children.len == 0) {
            try std.fmt.format(out, "<{s}>", .{self.name});
        } else {
            try out.print("<{s}>\n", .{self.name});
            for (self.children) |child| {
                try out.print("{}\n", .{child});
            }
            try out.print("</{s}>", .{self.name});
        }
    }
};

pub const E = Element;

pub fn element(comptime name: []const u8, children: anytype) Element {
    const ChildrenType = @TypeOf(children);
    const child_type_info = @typeInfo(ChildrenType);
    if (child_type_info == .Pointer) {
        return .{
            .name = name,
            .attrs = &[0]Attribute{},
            .children = children,
        };
    } else if (ChildrenType == Element) {
        const el = _alloc.alloc(Element, 1) catch unreachable;
        el[0] = children;
        return .{
            .name = name,
            .attrs = &[0]Attribute{},
            .children = el,
        };
    } else if (child_type_info == .Struct) {
        const fields_info = child_type_info.Struct.fields;
        if (fields_info.len != 0) {
            @compileError(".{} is the only child struct type"); // currently TODO plz fix
        }
        return .{
            .name = name,
            .attrs = &[0]Attribute{},
            .children = &[0]Element{},
        };
    } else {
        @compileError("children must be either Element, or []Element or .{}");
    }
    unreachable;
}

pub fn html(c: anytype) Element {
    return element("html", c);
}

pub fn head(c: anytype) Element {
    return element("head", c);
}

pub fn body(c: anytype) Element {
    return element("body", c);
}

pub fn div(c: anytype) Element {
    return element("div", c);
}

pub fn p(c: anytype) Element {
    return element("p", c);
}

pub fn span(c: anytype) Element {
    return element("span", c);
}

pub fn strong(c: anytype) Element {
    return element("strong", c);
}

test "html" {
    var a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    _alloc = arena.allocator();
    defer arena.deinit();

    const str = try std.fmt.allocPrint(a, "{}", .{html(&[_]Element{})});
    defer a.free(str);
    try std.testing.expectEqualStrings("<html>", str);

    const str2 = try std.fmt.allocPrint(a, "{}", .{html(body(.{}))});
    defer a.free(str2);
    try std.testing.expectEqualStrings("<html>\n<body>\n</html>", str2);
}

test "nested" {
    var a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    _alloc = arena.allocator();
    defer arena.deinit();
    const str = try std.fmt.allocPrint(a, "{}", .{
        html(&[_]E{
            head(.{}),
            body(
                div(p(.{})),
            ),
        }),
    });
    defer a.free(str);

    const example =
        \\<html>
        \\<head>
        \\<body>
        \\<div>
        \\<p>
        \\</div>
        \\</body>
        \\</html>
    ;
    try std.testing.expectEqualStrings(example, str);
}
