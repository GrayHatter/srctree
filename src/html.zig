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
    text: ?[]const u8 = null,
    attrs: ?[]const Attribute = null,
    children: ?[]const Element = null,

    pub fn format(self: Element, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        if (self.children) |children| {
            try out.print("<{s}>", .{self.name});
            for (children) |child| {
                if (child.text) |txt| {
                    try out.print("{s}", .{txt});
                    if (children.len == 1) break;
                } else {
                    try out.print("\n{}", .{child});
                }
            } else try out.writeAll("\n");
            try out.print("</{s}>", .{self.name});
        } else {
            if (self.text) |txt| {
                if (self.name[0] == '_') {
                    return try std.fmt.format(out, "{s}", .{txt});
                }
                return try std.fmt.format(out, "<{s}>{s}</{s}>", .{ self.name, txt, self.name });
            }
            try std.fmt.format(out, "<{s} />", .{self.name});
        }
    }
};

pub const E = Element;

/// TODO this desperately needs to return a type instead
pub fn element(comptime name: []const u8, children: anytype) Element {
    const ChildrenType = @TypeOf(children);
    if (ChildrenType == @TypeOf(null)) return .{ .name = name };
    const child_type_info = @typeInfo(ChildrenType);
    switch (child_type_info) {
        .Pointer => |ptr| switch (ptr.size) {
            .One => switch (@typeInfo(ptr.child)) {
                .Array => |arr| switch (arr.child) {
                    u8 => return .{
                        .name = name,
                        .text = children,
                    },
                    Element => {
                        return .{
                            .name = name,
                            .children = children,
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
                },
                else => {
                    @compileLog(ptr);
                    @compileLog(ptr.size);
                    @compileLog(ChildrenType);
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
                    };
                }
                @compileError(".{} is the only child struct type"); // currently TODO plz fix
            }
            return .{
                .name = name,
            };
        },
        else => @compileError("children must be either Element, or []Element or .{}"),
    }
    @compileError("Invalid type given for children when calling element");
}

pub fn text(c: []const u8) Element {
    return element("_text", c);
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
    init(a);
    defer raze();

    const str = try std.fmt.allocPrint(a, "{}", .{html(null)});
    defer a.free(str);
    try std.testing.expectEqualStrings("<html />", str);

    const str2 = try std.fmt.allocPrint(a, "{}", .{html(body(.{}))});
    defer a.free(str2);
    try std.testing.expectEqualStrings("<html>\n<body />\n</html>", str2);
}

test "nested" {
    var a = std.testing.allocator;
    init(a);
    defer raze();
    const str = try std.fmt.allocPrint(a, "{}", .{
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
        \\<head />
        \\<body>
        \\<div>
        \\<p />
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
