const std = @import("std");

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

pub fn element(comptime name: []const u8, comptime children: []const Element) Element {
    return .{
        .name = name,
        .attrs = &[0]Attribute{},
        .children = children,
    };
}

pub fn html(comptime c: []const Element) Element {
    return element("html", c);
}

pub fn head(comptime c: []const Element) Element {
    return element("head", c);
}

pub fn body(comptime c: []const Element) Element {
    return element("body", c);
}

pub fn div(comptime c: []const Element) Element {
    return element("div", c);
}

pub fn p(comptime c: []const Element) Element {
    return element("p", c);
}

pub fn span(comptime c: []const Element) Element {
    return element("span", c);
}

pub fn strong(comptime c: []const Element) Element {
    return element("strong", c);
}

test "html" {
    var a = std.testing.allocator;
    const str = try std.fmt.allocPrint(a, "{}", .{html(&[_]Element{})});
    defer a.free(str);
    try std.testing.expectEqualStrings("<html>", str);

    const str2 = try std.fmt.allocPrint(a, "{}", .{html(
        &[_]Element{body(&[_]Element{})},
    )});
    defer a.free(str2);
    try std.testing.expectEqualStrings("<html>\n<body>\n</html>", str2);
}

test "nested" {
    var a = std.testing.allocator;
    const str = try std.fmt.allocPrint(a, "{}", .{
        html(&[_]E{
            head(&[_]E{}),
            body(&[_]E{
                div(&[_]E{
                    p(&[_]E{}),
                }),
            }),
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
