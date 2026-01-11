pub fn highlight() void {}

pub fn translate(r: *Reader, w: *Writer, a: Allocator) !void {
    return try Translate.source(r, w, a);
}

const AST = struct {
    tree: void,
    //
    pub const Idx = struct {
        start: u32,
        len: u32,
    };

    pub const Line = struct {
        idx: Idx,
    };

    pub const Leaf = struct {
        idx: Idx,
    };

    pub const Block = struct {
        idx: Idx,
    };

    pub const List = struct {
        idx: Idx,
    };

    pub const Code = struct {
        idx: Idx,
    };
};

pub const Translate = struct {
    pub fn source(reader: *Reader, dst: *Writer, a: Allocator) error{ InvalidMarkdown, OutOfMemory, WriteFailed }!void {
        while (reader.bufferedLen() > 0) {
            block(reader, dst, a) catch |err| switch (err) {
                error.WriteFailed => return,
                inline else => |e| return e,
            };
        }
    }

    fn block(r: *Reader, dst: *Writer, a: Allocator) error{ InvalidMarkdown, OutOfMemory, WriteFailed }!void {
        //@setRuntimeSafety(false); // an LLVM bug causes this to crash
        if (r.bufferedLen() == 0) return;
        var indent = r.buffered();
        var indent_len: usize = 0;
        for (indent) |c| {
            if (c != ' ') break;
            indent_len += 1;
        }
        indent = indent[0..indent_len];
        for (indent) |c| assert(c == ' ');
        sw: switch (r.peekByte() catch return) {
            '\r', '\n' => {
                indent = &.{};
                indent_len = 0;
                r.toss(1);
                continue :sw r.peekByte() catch return;
            },
            ' ' => {
                var peek = r.buffered();
                while (indent_len < peek.len and peek[indent_len] == ' ') {
                    indent_len += 1;
                }
                indent = peek[0..indent_len];
                for (indent) |c| assert(c == ' ');
                continue :sw peek[indent_len];
            },
            '#' => {
                if (r.takeDelimiter('\n')) |until| {
                    header(until orelse r.take(r.bufferedLen()) catch unreachable, dst) catch return;
                } else |_| return;
                try dst.writeByte('\n');
                continue :sw r.peekByte() catch return;
            },
            '>' => {
                quote(r, dst, indent) catch return;
            },
            '`' => {
                if (eql(u8, r.peek(3) catch "", "```") and findPos(u8, r.buffered(), 3, "\n```") != null) {
                    code(r, dst, a) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.WriteFailed => return error.WriteFailed,
                        else => return error.InvalidMarkdown,
                    };
                } else {
                    paragraph(r, dst, indent) catch {};
                }
                continue :sw r.peekByte() catch return;
            },
            '-', '*', '+' => {
                if (indent_len > 0 and r.bufferedLen() > 2 and (r.peek(2) catch unreachable)[1] == ' ') {
                    list(r, dst, indent) catch {};
                } else {
                    paragraph(r, dst, indent) catch {};
                }
                continue :sw r.peekByte() catch return;
            },
            else => {
                paragraph(r, dst, indent) catch {};
                continue :sw r.peekByte() catch return;
            },
        }
    }

    fn header(src: []const u8, dst: *Writer) error{WriteFailed}!void {
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
                for (0..hlvl) |_| try dst.writeByte('#');
                break :t "";
            },
        };

        while (idx < src.len and src[idx] == ' ') idx += 1;
        try dst.writeAll(tag);
        if (findScalarPos(u8, src, idx, '\n')) |eol| {
            var i = eol;
            while (src[i] == '#' or src[i] == ' ' or src[i] == '\n') i -= 1;
            try dst.writeAll(src[idx .. i + 1]);
            idx = eol;
        } else {
            try dst.writeAll(src[idx..]);
            idx = src.len - 1;
        }
        if (tag.len > 1) {
            try dst.writeAll("</");
            try dst.writeAll(tag[1..]);
        }
        if (src[idx] != '\n') idx += 1;
    }

    fn quote(r: *Reader, dst: *Writer, indent: []const u8) error{WriteFailed}!void {
        _ = indent;
        const until = (r.takeDelimiter('\n') catch null) orelse r.take(r.bufferedLen()) catch unreachable;
        try dst.writeAll("<blockquote>");
        try line(until, dst);
        try dst.writeAll("</blockquote>\n");
    }

    fn paragraph(r: *Reader, dst: *Writer, indent: []const u8) error{ WriteFailed, Indent }!void {
        try dst.writeAll("<p>");
        const until = findPos(u8, r.buffered(), 0, "\n\n") orelse
            findPos(u8, r.buffered(), 0, "\r\n\r\n") orelse r.bufferedLen();
        var leaf_r: Reader = .fixed(r.take(until) catch unreachable);
        try leaf(&leaf_r, dst, indent);
        if (r.bufferedLen() >= 2) {
            if (r.peekByte() catch unreachable == '\r') r.toss(4) else r.toss(2);
        }
        try dst.writeAll("</p>\n");
    }

    fn code(reader: *Reader, dst: *Writer, a: Allocator) !void {
        std.debug.assert(eql(u8, try reader.take(3), "```"));
        // TODO does the closing ``` need a \n prefix
        const end = findPos(u8, reader.buffered(), 0, "\n```") orelse unreachable;
        var r: Reader = .fixed(reader.take(end) catch unreachable);
        reader.toss(4);

        const lang_name = r.peekDelimiterExclusive('\n') catch unreachable;
        var lang: ?[]const u8 = null;
        if (lang_name.len > 0) {
            for (lang_name) |chr| {
                if (chr < 'a' or chr > 'z') break;
            } else {
                lang = lang_name;
                r.toss(lang_name.len + 1);
            }
        }
        try dst.writeAll("<div class=\"codeblock\">");
        if (lang) |l| if (parseCodeblockFlavor(l)) |flavor| {
            try dst.writeAll(try syntax.highlight(a, flavor, r.buffered()));
            try dst.writeAll("</div>");
            return;
        };
        try dst.print("{s}</div>", .{trim(u8, r.buffered(), " \n")});
    }

    fn leaf(r: *Reader, dst: *Writer, indent: []const u8) error{ WriteFailed, Indent }!void {
        for (indent) |c| assert(c == ' ');
        while (r.peekDelimiterInclusive('\n') catch null) |until| {
            if (until.len == 1) {
                r.toss(1);
                continue;
            }
            var new_indent: u8 = 0;
            for (until) |chr| {
                if (chr != ' ') break;
                new_indent += 1;
            }
            const local_indent = if (new_indent > indent.len) until[0..new_indent] else indent;
            switch (until[new_indent]) {
                '-', '*', '+' => {
                    if (indent.len > 0 and until.len > new_indent + 2 and until[new_indent + 1] == ' ') {
                        try list(r, dst, local_indent);
                    } else {
                        try line(until[0 .. until.len - 1], dst);
                        r.toss(until.len);
                    }
                },
                else => {
                    try line(until[0 .. until.len - 1], dst);
                    r.toss(until.len);
                },
            }
            if (r.bufferedLen() == 0) return;
            try dst.writeByte(' ');
            continue;
        }

        try line(r.take(r.bufferedLen()) catch unreachable, dst);
    }

    fn list(r: *Reader, dst: *Writer, indent: []const u8) error{ WriteFailed, Indent }!void {
        for (indent) |c| assert(c == ' ');
        try dst.writeAll("<ul>\n");
        while (r.peekDelimiterExclusive('\n') catch null) |until_prefix| {
            var until = cutPrefix(u8, until_prefix, indent) orelse {
                try dst.writeAll("</ul>");
                return error.Indent;
            };
            //const until = until_prefix[0 .. until_prefix.len - 1];
            var new_indent: u8 = 0;
            for (until_prefix) |chr| {
                if (chr != ' ') break;
                new_indent += 1;
            }
            if (until.len <= 1) {
                r.toss(1);
                break;
            }
            if (new_indent > indent.len) {
                try dst.writeAll("<li>");
                list(r, dst, until_prefix[0..new_indent]) catch |err| switch (err) {
                    error.Indent => {
                        try dst.writeAll("</li>\n");
                        continue;
                    },
                    else => return err,
                };
            } else {
                try dst.writeAll("<li>");
                r.toss(indent.len);
                if (until[2] == '[' and until[4] == ']') {
                    try dst.print(
                        "<input type=\"checkbox\"{s}>",
                        .{if (until[3] == 'x' or until[3] == 'X') " checked" else ""},
                    );
                    r.toss(4);
                }
                r.toss(2);
                if (r.takeDelimiter('\n')) |lline| {
                    if (lline) |l| try line(trim(u8, l, "\t\n "), dst);
                } else |_| {}
                try dst.writeAll("</li>\n");
            }
        }
        try dst.writeAll("</ul>\n");
    }

    fn listOrdered(a: Allocator, src: []const u8, dst: *Writer, indent: usize) !void {
        _ = a;
        _ = src;
        _ = dst;
        _ = indent;
    }

    fn line(src: []const u8, dst: *Writer) error{WriteFailed}!void {
        var idx: usize = 0;
        while (idx < src.len) : (idx += 1) {
            switch (src[idx]) {
                '\\' => {
                    idx += 1;
                    if (idx < src.len)
                        try dst.writeByte(src[idx])
                    else
                        try dst.writeByte('\\');
                },
                '`' => {
                    if (findScalarPos(u8, src, idx + 1, '`')) |end| {
                        try dst.print("<span class=\"coderef\">{f}</span>", .{
                            abx.Html{ .text = src[idx + 1 .. end] },
                        });
                        idx = end;
                    }
                },
                '*' => {
                    if (idx + 7 < src.len and src[idx + 1] == '*' and src[idx + 2] == '*' and src[idx + 3] != ' ') {
                        if (findClosing(src[idx..], "***")) |estrong| {
                            try dst.print("<em><strong>{s}</strong></em>", .{estrong[3..]});
                            idx += estrong.len + 2;
                        }
                    } else if (idx + 5 < src.len and src[idx + 1] == '*' and src[idx + 2] != ' ') {
                        if (findClosing(src[idx..], "**")) |strong| {
                            try dst.print("<strong>{s}</strong>", .{strong[2..]});
                            idx += strong.len + 1;
                        }
                    } else if (idx + 2 < src.len and src[idx + 1] != ' ') {
                        if (findClosing(src[idx..], "*")) |em| {
                            try dst.print("<em>{s}</em>", .{em[1..]});
                            idx += em.len;
                        }
                    } else try dst.writeByte('*');
                },
                else => abx.Html.clean(src[idx], dst) catch unreachable,
                '\r' => {},
            }
        }
    }

    pub fn findClosing(src: []const u8, comptime tag: []const u8) ?[]const u8 {
        var search: usize = tag.len;
        while (search + tag.len < src.len) : (search += 1) {
            if (findPos(u8, src, search, tag)) |end| {
                if (src[end - 1] == ' ' or src[end - 1] == '\\') continue;
                return src[0..end];
            }
        }
        return null;
    }
};

/// Returns a slice into the given string IFF it's a supported language
fn parseCodeblockFlavor(str: []const u8) ?syntax.Language {
    return syntax.Language.fromString(str);
}

test "title 0" {
    const a = std.testing.allocator;
    const blob = "# Title";
    const expected = "<h1>Title</h1>\n";

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "title 1" {
    const a = std.testing.allocator;
    const blob = "# Title Title Title\n";
    const expected = "<h1>Title Title Title</h1>\n";

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
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
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "paragraph" {
    const a = std.testing.allocator;
    const blob =
        \\This is some
        \\
        \\Multi Line Text
        \\Same Line
        \\
        \\New line again
        \\
    ;
    const expected =
        \\<p>This is some</p>
        \\<p>Multi Line Text Same Line</p>
        \\<p>New line again</p>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "paragraph CRLF" {
    const a = std.testing.allocator;
    const blob =
        "This is some\r\n" ++
        "\r\n" ++
        "Multi Line Text\r\n" ++
        "Same Line\r\n" ++
        "\r\n" ++
        "New line again\r\n" ++
        "\r\n";
    const expected =
        \\<p>This is some</p>
        \\<p>Multi Line Text Same Line</p>
        \\<p>New line again</p>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "backtick" {
    const a = std.testing.allocator;
    const blob = "`backtick`";
    const expected = "<p><span class=\"coderef\">backtick</span></p>\n";

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "backtick block" {
    const a = std.testing.allocator;
    {
        const blob = "```backtick block\n```";
        const expected = "<div class=\"codeblock\">backtick block</div>";

        var r: Reader = .fixed(blob);
        var w: Writer.Allocating = .init(a);
        try Translate.source(&r, &w.writer, a);
        defer w.deinit();

        try std.testing.expectEqualStrings(expected, w.written());
    }
    {
        const blob = "```backtick```";
        const expected = "<p><span class=\"coderef\"></span><span class=\"coderef\">backtick</span><span class=\"coderef\"></span></p>\n";

        var r: Reader = .fixed(blob);
        var w: Writer.Allocating = .init(a);
        try Translate.source(&r, &w.writer, a);
        defer w.deinit();

        try std.testing.expectEqualStrings(expected, w.written());
    }
}

test "list" {
    const a = std.testing.allocator;
    const blob =
        \\  * hi, mom
        \\  * hello world
        \\  * smile, smile!
        \\  * <extra code>
        \\
    ;
    const expected =
        \\<ul>
        \\<li>hi, mom</li>
        \\<li>hello world</li>
        \\<li>smile, smile!</li>
        \\<li>&lt;extra code&gt;</li>
        \\</ul>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "list nested" {
    const a = std.testing.allocator;
    const blob =
        \\  * hi, mom
        \\  * hello world
        \\  * smile, smile!
        \\    * nested
        \\    * lists
        \\    * work
        \\  * <extra code>
        \\
    ;
    const expected =
        \\<ul>
        \\<li>hi, mom</li>
        \\<li>hello world</li>
        \\<li>smile, smile!</li>
        \\<li><ul>
        \\<li>nested</li>
        \\<li>lists</li>
        \\<li>work</li>
        \\</ul></li>
        \\<li>&lt;extra code&gt;</li>
        \\</ul>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "em" {
    const a = std.testing.allocator;
    const blob =
        \\*hi, mom*
        \\
    ;
    const expected =
        \\<p><em>hi, mom</em></p>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "em2" {
    const a = std.testing.allocator;
    const blob =
        \\*hi, mom* *other line*
        \\
    ;
    const expected =
        \\<p><em>hi, mom</em> <em>other line</em></p>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "em3" {
    const a = std.testing.allocator;
    const blob =
        \\* hi, mom*
        \\
    ;
    const expected =
        \\<p>* hi, mom*</p>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "strong" {
    const a = std.testing.allocator;
    const blob =
        \\**hi, mom**
        \\
    ;
    const expected =
        \\<p><strong>hi, mom</strong></p>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "strong2" {
    const a = std.testing.allocator;
    const blob =
        \\**strong** **like bull!**
        \\
    ;
    const expected =
        \\<p><strong>strong</strong> <strong>like bull!</strong></p>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "em+strong" {
    const a = std.testing.allocator;
    const blob =
        \\***hi, mom***
        \\
    ;
    const expected =
        \\<p><em><strong>hi, mom</strong></em></p>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

const syntax = @import("../syntax-highlight.zig");
const abx = @import("verse").abx;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const eql = std.mem.eql;
const trim = std.mem.trim;
const findScalarPos = std.mem.findScalarPos;
const findPos = std.mem.findPos;
const cutPrefix = std.mem.cutPrefix;
const assert = std.debug.assert;
