const std = @import("std");
const Allocator = std.mem.Allocator;

var _arena: std.heap.ArenaAllocator = undefined;
var _alloc: Allocator = undefined;
// TODO areana allocator with deinit

pub fn init(a: Allocator) void {
    _arena = std.heap.ArenaAllocator.init(a);
    _alloc = _arena.allocator();
}

pub fn raze() void {
    _arena.deinit();
}

pub const Attribute = struct {
    key: []const u8,
    value: ?[]const u8,

    /// Helper function
    pub fn class(val: ?[]const u8) Attribute {
        return .{
            .key = "class",
            .value = val,
        };
    }

    pub fn format(self: Attribute, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        if (self.value) |value| {
            try std.fmt.format(out, " {s}=\"{s}\"", .{ self.key, value });
        } else {
            try std.fmt.format(out, " {s}", .{self.key});
        }
    }
};

pub const Element = struct {
    name: []const u8,
    text: ?[]const u8 = null,
    attrs: ?[]const Attribute = null,
    children: ?[]const Element = null,
    self_close: bool = false,

    pub fn format(self: Element, comptime fmt: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        const pretty = std.mem.eql(u8, fmt, "pretty");

        if (self.name[0] == '_') {
            if (self.text) |txt| {
                return try std.fmt.format(out, "{s}", .{txt});
            }
        }

        try out.print("<{s}", .{self.name});
        if (self.attrs) |attrs| {
            for (attrs) |attr| try out.print("{}", .{attr});
        }
        try out.print(">", .{});

        if (self.children) |children| {
            for (children) |child| {
                if (pretty) {
                    try out.print("\n{pretty}", .{child});
                } else {
                    try out.print("{}", .{child});
                }
            } else if (pretty) try out.writeAll("\n");
        } else if (self.text) |txt| {
            try out.print("{s}", .{txt});
        } else if (self.self_close) {
            return try out.print(" />", .{});
        }
        try out.print("</{s}>", .{self.name});
    }
};

pub const E = Element;

/// TODO this desperately needs to return a type instead
pub fn element(comptime name: []const u8, children: anytype, attrs: ?[]const Attribute) Element {
    const ChildrenType = @TypeOf(children);
    if (ChildrenType == @TypeOf(null)) return .{ .name = name, .attrs = attrs };
    const child_type_info = @typeInfo(ChildrenType);
    switch (child_type_info) {
        .Pointer => |ptr| switch (ptr.size) {
            .One => switch (@typeInfo(ptr.child)) {
                .Array => |arr| switch (arr.child) {
                    u8 => return .{
                        .name = name,
                        .text = children,
                        .attrs = attrs,
                    },
                    Element => {
                        return .{
                            .name = name,
                            .children = children,
                            .attrs = attrs,
                        };
                    },
                    else => @compileError("Unknown type given to element"),
                },
                else => {
                    @compileLog(ptr);
                    @compileLog(ptr.size);
                    @compileLog(ChildrenType);
                },
            },
            .Slice => switch (ptr.child) {
                u8 => return .{
                    .name = name,
                    .text = children,
                    .attrs = attrs,
                },
                Element => return .{
                    .name = name,
                    .children = children,
                    .attrs = attrs,
                },
                else => {
                    @compileLog(ptr);
                    @compileLog(ptr.child);
                    @compileLog(ptr.size);
                    @compileLog(ChildrenType);
                    @compileError("Invalid pointer children given");
                },
            },
            else => {
                @compileLog(ptr);
                @compileLog(ptr.size);
                @compileLog(ChildrenType);
            },
        },
        .Struct => |srt| {
            const fields_info = srt.fields;
            if (fields_info.len != 0) {
                if (ChildrenType == Element) {
                    const el = _alloc.alloc(Element, 1) catch unreachable;
                    el[0] = children;
                    return .{
                        .name = name,
                        .children = el,
                        .attrs = attrs,
                    };
                }
                @compileError(".{} is the only child struct type"); // currently TODO plz fix
            }
            return .{
                .name = name,
                .attrs = attrs,
            };
        },
        .Array => |arr| switch (arr.child) {
            // TODO, this is probably a compiler error, prefix with &
            Element => return .{
                .name = name,
                .children = children.ptr,
                .attrs = attrs,
            },
            else => {
                @compileLog(ChildrenType);
                @compileLog(@typeInfo(ChildrenType));
                @compileError("children must be either Element, or []Element or .{}");
            },
        },
        else => {
            @compileLog(ChildrenType);
            @compileLog(@typeInfo(ChildrenType));
            @compileError("children must be either Element, or []Element or .{}");
        },
    }
    @compileLog(ChildrenType);
    @compileLog(@typeInfo(ChildrenType));
    @compileError("Invalid type given for children when calling element");
}

pub fn text(c: []const u8) Element {
    return element("_text", c, null);
}

pub fn html(c: anytype) Element {
    return element("html", c, null);
}

pub fn head(c: anytype) Element {
    return element("head", c, null);
}

pub fn body(c: anytype) Element {
    return element("body", c, null);
}

pub fn div(c: anytype) Element {
    return element("div", c, null);
}

/// Creating a 2nd type because I'm not sure what I want this API to actually
/// look like yet
pub fn divAttr(c: anytype, attr: ?[]const Attribute) Element {
    return element("div", c, attr);
}

pub fn p(c: anytype) Element {
    return element("p", c, null);
}

pub fn span(c: anytype) Element {
    return element("span", c, null);
}

pub fn strong(c: anytype) Element {
    return element("strong", c, null);
}

pub fn anch(c: anytype, attr: ?[]const Attribute) Element {
    return element("a", c, attr);
}

pub fn li(c: anytype, attr: ?[]const Attribute) Element {
    return element("li", c, attr);
}

test "html" {
    var a = std.testing.allocator;
    init(a);
    defer raze();

    const str = try std.fmt.allocPrint(a, "{}", .{html(null)});
    defer a.free(str);
    try std.testing.expectEqualStrings("<html></html>", str);

    const str2 = try std.fmt.allocPrint(a, "{pretty}", .{html(body(.{}))});
    defer a.free(str2);
    try std.testing.expectEqualStrings("<html>\n<body></body>\n</html>", str2);
}

test "nested" {
    var a = std.testing.allocator;
    init(a);
    defer raze();
    const str = try std.fmt.allocPrint(a, "{pretty}", .{
        html(&[_]E{
            head(null),
            body(
                div(p(null)),
            ),
        }),
    });
    defer a.free(str);

    const example =
        \\<html>
        \\<head></head>
        \\<body>
        \\<div>
        \\<p></p>
        \\</div>
        \\</body>
        \\</html>
    ;
    try std.testing.expectEqualStrings(example, str);
}

test "text" {
    var a = std.testing.allocator;
    init(a);
    defer raze();

    const str = try std.fmt.allocPrint(a, "{}", .{text("this is text")});
    defer a.free(str);
    try std.testing.expectEqualStrings("this is text", str);

    const pt = try std.fmt.allocPrint(a, "{}", .{p("this is text")});
    defer a.free(pt);
    try std.testing.expectEqualStrings("<p>this is text</p>", pt);

    const p_txt = try std.fmt.allocPrint(a, "{}", .{p(text("this is text"))});
    defer a.free(p_txt);
    try std.testing.expectEqualStrings("<p>this is text</p>", p_txt);
}

test "attrs" {
    var a = std.testing.allocator;
    init(a);
    defer raze();
    const str = try std.fmt.allocPrint(a, "{pretty}", .{
        html(&[_]E{
            head(null),
            body(
                divAttr(p(null), &[_]Attribute{
                    Attribute{ .key = "class", .value = "something" },
                }),
            ),
        }),
    });
    defer a.free(str);

    const example =
        \\<html>
        \\<head></head>
        \\<body>
        \\<div class="something">
        \\<p></p>
        \\</div>
        \\</body>
        \\</html>
    ;
    try std.testing.expectEqualStrings(example, str);
}
