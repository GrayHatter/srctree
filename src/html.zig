const std = @import("std");
const Allocator = std.mem.Allocator;

pub usingnamespace @import("html/extra.zig");

pub const Attribute = struct {
    key: []const u8,
    value: ?[]const u8,

    /// Helper function
    pub fn class(val: ?[]const u8) [1]Attribute {
        return [_]Attr{
            .{ .key = "class", .value = val },
        };
    }

    pub fn alloc(a: Allocator, keys: []const []const u8, vals: []const ?[]const u8) ![]Attribute {
        var all = try a.alloc(Attribute, @max(keys.len, vals.len));
        for (all, keys, vals) |*dst, k, v| {
            dst.* = Attribute{
                .key = try a.dupe(u8, k),
                .value = if (v) |va| try a.dupe(u8, va) else null,
            };
        }
        return all;
    }

    pub fn create(a: Allocator, k: []const u8, v: ?[]const u8) ![]Attribute {
        return alloc(a, &[_][]const u8{k}, &[_]?[]const u8{v});
    }

    pub fn format(self: Attribute, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        if (self.value) |value| {
            try std.fmt.format(out, " {s}=\"{s}\"", .{ self.key, value });
        } else {
            try std.fmt.format(out, " {s}", .{self.key});
        }
    }
};

pub const Attr = Attribute;

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
        if (self.self_close) {
            return try out.print(" />", .{});
        } else try out.print(">", .{});

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
                .Pointer => @compileError("Pointer to a pointer, (perhaps &[]u8) did you mistakenly add a &?"),
                else => {
                    @compileLog(ptr);
                    @compileLog(ptr.child);
                    @compileLog(@typeInfo(ptr.child));
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
        .Struct => @compileError("Raw structs aren't allowed, element must be a slice"),
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

pub fn div(c: anytype, a: ?[]const Attribute) Element {
    return element("div", c, a);
}

pub fn h1(c: anytype, a: ?[]const Attribute) Element {
    return element("h1", c, a);
}

pub fn h2(c: anytype, a: ?[]const Attribute) Element {
    return element("h2", c, a);
}

pub fn h3(c: anytype, a: ?[]const Attribute) Element {
    return element("h3", c, a);
}

pub fn p(c: anytype, a: ?[]const Attribute) Element {
    return element("p", c, a);
}

pub fn br() Element {
    var _br = element("br", null, null);
    _br.self_close = true;
    return _br;
}

pub fn span(c: anytype, a: ?[]const Attribute) Element {
    return element("span", c, a);
}

pub fn strong(c: anytype) Element {
    return element("strong", c, null);
}

pub fn anch(c: anytype, attr: ?[]const Attribute) Element {
    return element("a", c, attr);
}

pub fn aHrefText(a: Allocator, txt: []const u8, href: []const u8) !Element {
    var attr = try a.alloc(Attribute, 1);
    attr[0] = Attribute{
        .key = "href",
        .value = href,
    };
    return anch(txt, attr);
}

pub fn form(c: anytype, attr: ?[]const Attribute) Element {
    return element("form", c, attr);
}

pub fn btn(c: anytype, attr: ?[]const Attribute) Element {
    return element("button", c, attr);
}

pub fn linkBtnAlloc(a: Allocator, txt: []const u8, href: []const u8) !Element {
    const attr = [2]Attr{
        Attr.class("btn")[0],
        Attr{
            .key = "href",
            .value = href,
        },
    };
    return element(
        "a",
        try a.dupe(u8, txt),
        try a.dupe(Attr, &attr),
    );
}

pub fn li(c: anytype, attr: ?[]const Attribute) Element {
    return element("li", c, attr);
}

test "html" {
    var a = std.testing.allocator;

    const str = try std.fmt.allocPrint(a, "{}", .{html(null)});
    defer a.free(str);
    try std.testing.expectEqualStrings("<html></html>", str);

    const str2 = try std.fmt.allocPrint(a, "{pretty}", .{html(&[_]E{body(null)})});
    defer a.free(str2);
    try std.testing.expectEqualStrings("<html>\n<body></body>\n</html>", str2);
}

test "nested" {
    var a = std.testing.allocator;
    const str = try std.fmt.allocPrint(a, "{pretty}", .{
        html(&[_]E{
            head(null),
            body(
                &[_]E{div(&[_]E{p(null, null)}, null)},
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

    const str = try std.fmt.allocPrint(a, "{}", .{text("this is text")});
    defer a.free(str);
    try std.testing.expectEqualStrings("this is text", str);

    const pt = try std.fmt.allocPrint(a, "{}", .{p("this is text", null)});
    defer a.free(pt);
    try std.testing.expectEqualStrings("<p>this is text</p>", pt);

    const p_txt = try std.fmt.allocPrint(a, "{}", .{p(&[_]E{text("this is text")}, null)});
    defer a.free(p_txt);
    try std.testing.expectEqualStrings("<p>this is text</p>", p_txt);
}

test "attrs" {
    var a = std.testing.allocator;
    const str = try std.fmt.allocPrint(a, "{pretty}", .{
        html(&[_]E{
            head(null),
            body(
                &[_]E{div(&[_]E{p(null, null)}, &[_]Attribute{
                    Attribute{ .key = "class", .value = "something" },
                })},
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
