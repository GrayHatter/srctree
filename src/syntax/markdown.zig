pub fn highlight() void {}

pub fn translate(a: Allocator, blob: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(a);
    var newline: u8 = 255;
    var idx: usize = 0;
    var backtick: bool = false;
    var esc = true;
    while (idx < blob.len) : (idx += 1) {
        sw: switch (blob[idx]) {
            '\n' => {
                newline +|= 1;
                if (newline % 2 == 0) {
                    try output.appendSlice("<br>");
                }
                try output.append('\n');
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
                if (blob.len > idx + 7) {
                    if (blob[idx + 1] == '`' and blob[idx + 2] == '`') {
                        // TODO does the closing ``` need a \n prefix
                        if (std.mem.indexOfPos(u8, blob, idx + 3, "\n```")) |i| {
                            var highlighted: ?[]const u8 = null;
                            defer if (highlighted) |hl| a.free(hl);

                            if (blob[idx + 3] >= 'a' and blob[idx + 3] <= 'z') {
                                var lang_len = idx + 3;
                                while (lang_len < i and blob[lang_len] >= 'a' and blob[lang_len] <= 'z') {
                                    lang_len += 1;
                                }
                                if (parseCodeblockFlavor(blob[idx + 3 .. lang_len])) |flavor| {
                                    highlighted = try syntax.highlight(a, flavor, blob[lang_len..i]);
                                }
                            }

                            try output.appendSlice("<div class=\"codeblock\">");
                            idx += 3;
                            try output.appendSlice(highlighted orelse blob[idx..i]);
                            try output.appendSlice("\n</div>");
                            idx = i + 4;
                            if (idx >= blob.len) break :sw;
                            continue :sw blob[idx];
                        }
                    }
                }
                if (backtick) {
                    backtick = false;
                    try output.appendSlice("</span>");
                } else {
                    backtick = true;
                    try output.appendSlice("<span class=\"coderef\">");
                }
            },
            '\\' => {
                if (idx + 1 >= blob.len) {
                    try output.append('\\');
                    break;
                }
                idx += 1;
                switch (blob[idx]) {
                    '\\' => {
                        try output.append('\\');
                        idx += 1;
                    },
                    '`' => |c| {
                        try output.append(c);
                        idx += 1;
                    },
                    else => {},
                }
                continue :sw blob[idx];
            },
            else => |c| {
                newline = 0;
                esc = false;
                if (abx.Html.clean(c)) |clean| {
                    try output.appendSlice(clean);
                } else {
                    try output.append(c);
                }
            },
        }
    }

    return try output.toOwnedSlice();
}

/// Returns a slice into the given string IFF it's a supported language
fn parseCodeblockFlavor(str: []const u8) ?syntax.Language {
    return syntax.Language.fromString(str);
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

test "backtick block" {
    const a = std.testing.allocator;
    {
        const blob = "```backtick block\n```";
        const expected = "<div class=\"codeblock\">backtick block\n</div>";

        const html = try translate(a, blob);
        defer a.free(html);

        try std.testing.expectEqualStrings(expected, html);
    }
    {
        const blob = "```backtick```";
        const expected = "<span class=\"coderef\"></span><span class=\"coderef\">backtick</span><span class=\"coderef\"></span>";

        const html = try translate(a, blob);
        defer a.free(html);

        try std.testing.expectEqualStrings(expected, html);
    }
}

const syntax = @import("../syntax-highlight.zig");
const abx = @import("verse").abx;

const std = @import("std");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
