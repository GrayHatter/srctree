const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn highlight() void {}

pub fn translate(a: Allocator, blob: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(a);
    var newline: u8 = 255;
    var idx: usize = 0;
    var backtick: bool = false;
    while (idx < blob.len) : (idx += 1) {
        switch (blob[idx]) {
            '\n' => |c| {
                newline +|= 1;
                if (newline % 2 == 0) {
                    try output.appendSlice("<br>");
                }
                try output.append(c);
            },
            '#' => |c| {
                if (newline == 0) {
                    try output.append(c);
                    continue;
                }

                newline = 0;
                var hlvl: u8 = 0;
                while (idx < blob.len) : (idx += 1) {
                    switch (blob[idx]) {
                        '#' => hlvl +|= 1,
                        else => break,
                    }
                }
                const tag = switch (hlvl) {
                    1 => "<h1>",
                    2 => "<h2>",
                    3 => "<h3>",
                    4 => "<h4>",
                    5 => "<h5>",
                    6 => "<h6>",
                    else => t: {
                        for (0..hlvl) |_| try output.append('#');
                        break :t "";
                    },
                };

                try output.appendSlice(tag);
                while (idx < blob.len and blob[idx] == ' ') idx += 1;
                while (idx < blob.len and blob[idx] != '\n') : (idx += 1) {
                    try output.append(blob[idx]);
                }
                if (idx != blob.len) idx -= 1;
                if (tag.len > 1) {
                    try output.appendSlice("</");
                    try output.appendSlice(tag[1..]);
                }
            },
            '`' => {
                if (backtick) {
                    backtick = false;
                    try output.appendSlice("</span>");
                } else {
                    backtick = true;
                    try output.appendSlice("<span class=\"coderef\">");
                }
            },
            else => |c| {
                newline = 0;
                try output.append(c);
            },
        }
    }

    return try output.toOwnedSlice();
}

test "title 0" {
    const a = std.testing.allocator;
    const blob = "# Title";
    const expected = "<h1>Title</h1>";

    const html = try translate(a, blob);
    defer a.free(html);

    try std.testing.expectEqualStrings(expected, html);
}

test "title 1" {
    const a = std.testing.allocator;
    const blob = "# Title Title Title\n\n\n";
    const expected = "<h1>Title Title Title</h1>\n<br>\n\n";

    const html = try translate(a, blob);
    defer a.free(html);

    try std.testing.expectEqualStrings(expected, html);
}

test "title 2" {
    const a = std.testing.allocator;
    const blob =
        \\# Title
        \\
        \\## Fake Title
        \\
        \\# Other Title
        \\
        \\text
        \\
    ;

    const expected =
        \\<h1>Title</h1>
        \\<br>
        \\<h2>Fake Title</h2>
        \\<br>
        \\<h1>Other Title</h1>
        \\<br>
        \\text
        \\
    ;

    const html = try translate(a, blob);
    defer a.free(html);

    try std.testing.expectEqualStrings(expected, html);
}

test "backtick" {
    const a = std.testing.allocator;
    const blob = "`backtick`";
    const expected = "<span class=\"coderef\">backtick</span>";

    const html = try translate(a, blob);
    defer a.free(html);

    try std.testing.expectEqualStrings(expected, html);
}
