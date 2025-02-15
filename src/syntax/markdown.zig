pub fn highlight() void {}

pub fn translate(a: Allocator, blob: []const u8) ![]u8 {
    return try Translate.source(a, blob);
}

pub const Translate = struct {
    pub fn source(a: Allocator, src: []const u8) ![]u8 {
        var dst = std.ArrayList(u8).init(a);
        var used = try block(src, &dst, a);
        while (used < src.len) {
            used += try block(src[used..], &dst, a);
        }
        return try dst.toOwnedSlice();
    }

    fn block(src: []const u8, dst: *ArrayList(u8), a: Allocator) !usize {
        var idx: usize = 0;
        while (idx < src.len and (src[idx] == ' ' or src[idx] == '\t')) {
            idx = idx + if (src[idx] == '\t') 4 else @as(usize, 1);
        }
        const indent = idx;
        _ = indent;

        sw: switch (src[idx]) {
            '\n' => {
                idx += 1;
                if (idx < src.len) {
                    continue :sw src[idx];
                }
            },
            '#' => {
                const until = indexOfScalarPos(u8, src, idx, '\n') orelse src.len;
                try header(src[idx..until], dst);
                idx = until;
                if (idx < src.len) {
                    try dst.append('\n');
                    continue :sw src[idx];
                }
            },
            '>' => {
                try quote(src[idx..], dst);
            },
            '`' => {
                if (idx + 7 < src.len and
                    src[idx + 1] == '`' and src[idx + 2] == '`' and
                    indexOfPos(u8, src, idx + 3, "\n```") != null)
                {
                    idx += try code(src[idx..], dst, a);
                } else {
                    try dst.appendSlice("<p>");
                    const until = indexOfPos(u8, src, idx, "\n\n") orelse src.len;
                    try leaf(src[idx..until], dst);
                    try dst.appendSlice("</p>");
                    idx = until + 2;
                    if (idx < src.len) continue :sw src[idx];
                }
            },
            else => {
                try dst.appendSlice("<p>");
                const until = indexOfPos(u8, src, idx, "\n\n") orelse src.len;
                try leaf(src[idx..until], dst);
                try dst.appendSlice("</p>");
                idx = until + 2;
                if (idx < src.len) continue :sw src[idx];
            },
        }
        return idx;
    }

    fn header(src: []const u8, dst: *ArrayList(u8)) !void {
        var idx: usize = 0;
        var hlvl: u8 = 0;
        while (idx < src.len) : (idx += 1) {
            switch (src[idx]) {
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
                for (0..hlvl) |_| try dst.append('#');
                break :t "";
            },
        };

        while (idx < src.len and src[idx] == ' ') idx += 1;
        try dst.appendSlice(tag);
        if (indexOfScalarPos(u8, src, idx, '\n')) |eol| {
            var i = eol;
            while (src[i] == '#' or src[i] == ' ' or src[i] == '\n') i -= 1;
            try dst.appendSlice(src[idx .. i + 1]);
            idx = eol;
        } else {
            try dst.appendSlice(src[idx..]);
            idx = src.len - 1;
        }
        if (tag.len > 1) {
            try dst.appendSlice("</");
            try dst.appendSlice(tag[1..]);
        }
        if (src[idx] != '\n') idx += 1;
    }

    fn quote(src: []const u8, dst: *ArrayList(u8)) !void {
        _ = src;
        _ = dst;
    }

    fn code(src: []const u8, dst: *ArrayList(u8), a: Allocator) !usize {
        var idx: usize = 0;
        if (src.len > idx + 7) {
            if (src[idx + 1] == '`' and src[idx + 2] == '`') {
                // TODO does the closing ``` need a \n prefix
                if (std.mem.indexOfPos(u8, src, idx + 3, "\n```")) |i| {
                    var highlighted: ?[]const u8 = null;
                    defer if (highlighted) |hl| a.free(hl);

                    if (src[idx + 3] >= 'a' and src[idx + 3] <= 'z') {
                        var lang_len = idx + 3;
                        while (lang_len < i and src[lang_len] >= 'a' and src[lang_len] <= 'z') {
                            lang_len += 1;
                        }
                        if (parseCodeblockFlavor(src[idx + 3 .. lang_len])) |flavor| {
                            highlighted = try syntax.highlight(a, flavor, src[lang_len..i]);
                        }
                    }

                    try dst.appendSlice("<div class=\"codeblock\">");
                    idx += 3;
                    try dst.appendSlice(highlighted orelse src[idx..i]);
                    try dst.appendSlice("\n</div>");
                    idx = i + 4;
                }
            }
        }
        return idx;
    }

    fn leaf(src: []const u8, dst: *ArrayList(u8)) !void {
        var idx: usize = 0;
        while (indexOfScalarPos(u8, src, idx, '\n')) |i| {
            try line(src[idx..i], dst);
            if (i + 1 >= src.len) return;
            idx = i + 1;
        }
        if (idx >= src.len) return;
        try line(src[idx..], dst);
    }

    fn line(src: []const u8, dst: *ArrayList(u8)) !void {
        var backtick: bool = false;
        var idx: usize = 0;
        while (idx < src.len) : (idx += 1) {
            switch (src[idx]) {
                '\\' => {
                    idx += 1;
                    if (idx >= src.len) {
                        try dst.append(src[idx]);
                    }
                },
                '`' => {
                    if (backtick) {
                        backtick = false;
                        try dst.appendSlice("</span>");
                    } else if (indexOfScalarPos(u8, src, idx + 1, '`') != null) {
                        backtick = true;
                        try dst.appendSlice("<span class=\"coderef\">");
                    } else {
                        try dst.append('`');
                    }
                },
                else => {
                    if (abx.Html.clean(src[idx])) |clean| {
                        try dst.appendSlice(clean);
                    } else {
                        try dst.append(src[idx]);
                    }
                },
            }
        }
    }
};

/// Returns a slice into the given string IFF it's a supported language
fn parseCodeblockFlavor(str: []const u8) ?syntax.Language {
    return syntax.Language.fromString(str);
}

test "title 0" {
    const a = std.testing.allocator;
    const blob = "# Title";
    const expected = "<h1>Title</h1>";

    const html = try Translate.source(a, blob);
    defer a.free(html);

    try std.testing.expectEqualStrings(expected, html);
}

test "title 1" {
    const a = std.testing.allocator;
    const blob = "# Title Title Title\n";
    const expected = "<h1>Title Title Title</h1>\n";

    const html = try Translate.source(a, blob);
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
        \\<h2>Fake Title</h2>
        \\<h1>Other Title</h1>
        \\<p>text</p>
    ;

    const html = try Translate.source(a, blob);
    defer a.free(html);

    try std.testing.expectEqualStrings(expected, html);
}

test "backtick" {
    const a = std.testing.allocator;
    const blob = "`backtick`";
    const expected = "<p><span class=\"coderef\">backtick</span></p>";

    const html = try Translate.source(a, blob);
    defer a.free(html);

    try std.testing.expectEqualStrings(expected, html);
}

test "backtick block" {
    const a = std.testing.allocator;
    {
        const blob = "```backtick block\n```";
        const expected = "<div class=\"codeblock\">backtick block\n</div>";

        const html = try Translate.source(a, blob);
        defer a.free(html);

        try std.testing.expectEqualStrings(expected, html);
    }
    {
        const blob = "```backtick```";
        const expected = "<p><span class=\"coderef\"></span><span class=\"coderef\">backtick</span><span class=\"coderef\"></span></p>";

        const html = try Translate.source(a, blob);
        defer a.free(html);

        try std.testing.expectEqualStrings(expected, html);
    }
}

const syntax = @import("../syntax-highlight.zig");
const abx = @import("verse").abx;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const indexOfPos = std.mem.indexOfPos;
