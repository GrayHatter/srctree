pub fn highlight() void {}

pub fn translate(r: *Reader, w: *Writer, a: Allocator, io: Io) !void {
    return try Translate.source(r, w, a, io);
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
    pub fn source(reader: *Reader, dst: *Writer, a: Allocator, io: Io) error{ InvalidMarkdown, OutOfMemory, WriteFailed }!void {
        while (reader.bufferedLen() > 0) {
            block(reader, dst, a, io) catch |err| switch (err) {
                error.WriteFailed => return,
                inline else => |e| return e,
            };
        }
    }

    fn block(r: *Reader, dst: *Writer, a: Allocator, io: Io) error{ InvalidMarkdown, OutOfMemory, WriteFailed }!void {
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
                    header(until orelse return, dst) catch return;
                } else |_| return;
                try dst.writeByte('\n');
                continue :sw r.peekByte() catch return;
            },
            '>' => {
                quote(r, dst) catch return;
                continue :sw r.peekByte() catch return;
            },
            '`' => {
                if (eql(u8, r.peek(3) catch "", "```") and findPos(u8, r.buffered(), 3, "\n```") != null) {
                    code(r, dst, a, io) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.WriteFailed => return error.WriteFailed,
                        else => return error.InvalidMarkdown,
                    };
                } else {
                    paragraph(r, dst, indent) catch |err| switch (err) {
                        error.Indent => {
                            indent = &.{};
                            indent_len = 0;
                        },
                        error.WriteFailed => return error.WriteFailed,
                    };
                }
                continue :sw r.peekByte() catch return;
            },
            '-', '*', '+' => {
                if (indent_len > 0 and r.bufferedLen() > 2 and (r.peek(2) catch unreachable)[1] == ' ') {
                    list(r, dst, indent) catch |err| switch (err) {
                        error.Indent => {
                            indent = &.{};
                            indent_len = 0;
                        },
                        error.WriteFailed => return error.WriteFailed,
                    };
                } else {
                    paragraph(r, dst, indent) catch |err| switch (err) {
                        error.Indent => {
                            indent = &.{};
                            indent_len = 0;
                        },
                        error.WriteFailed => return error.WriteFailed,
                    };
                }
                continue :sw r.peekByte() catch return;
            },
            else => {
                paragraph(r, dst, indent) catch |err| switch (err) {
                    error.Indent => {
                        indent = &.{};
                        indent_len = 0;
                    },
                    error.WriteFailed => return error.WriteFailed,
                };

                continue :sw r.peekByte() catch return;
            },
        }
    }

    fn header(src: []const u8, dst: *Writer) error{WriteFailed}!void {
        var idx: usize = 0;
        while (idx < src.len and src[idx] == '#' and idx < 100) : (idx += 1) {}

        switch (idx) {
            1 => try dst.print("<h1>{s}</h1>", .{trim(u8, src[idx..], "\n ")}),
            2 => try dst.print("<h2>{s}</h2>", .{trim(u8, src[idx..], "\n ")}),
            3 => try dst.print("<h3>{s}</h3>", .{trim(u8, src[idx..], "\n ")}),
            4 => try dst.print("<h4>{s}</h4>", .{trim(u8, src[idx..], "\n ")}),
            5 => try dst.print("<h5>{s}</h5>", .{trim(u8, src[idx..], "\n ")}),
            6 => try dst.print("<h6>{s}</h6>", .{trim(u8, src[idx..], "\n ")}),
            else => |cnt| {
                _ = try dst.splatByte('#', cnt);
                try dst.writeAll(src[idx..]);
            },
        }
    }

    fn quote(r: *Reader, dst: *Writer) error{WriteFailed}!void {
        const until = (r.takeDelimiter('\n') catch null) orelse r.take(r.bufferedLen()) catch unreachable;
        try dst.writeAll("<blockquote>");
        try lineBasic(until, dst);
        try dst.writeAll("</blockquote>\n");
    }

    fn paragraph(r: *Reader, dst: *Writer, indent: []const u8) error{ WriteFailed, Indent }!void {
        try dst.writeAll("<p>");
        const until: usize = findPos(u8, r.buffered(), 0, "\n\n") orelse
            findPos(u8, r.buffered(), 0, "\r\n\r\n") orelse
            r.bufferedLen();
        const extra: usize = if (until == r.bufferedLen())
            0
        else if (r.bufferedLen() >= 4 and r.peekByte() catch unreachable == '\r')
            2
        else
            1;

        const bytes = r.take(until + extra) catch unreachable;
        var leaf_r: Reader = .fixed(bytes);
        try leaf(&leaf_r, dst, indent);

        try dst.writeAll("</p>\n");
    }

    fn code(reader: *Reader, dst: *Writer, a: Allocator, io: Io) !void {
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
            try dst.writeAll(try syntax.highlight(flavor, r.buffered(), a, io));
            try dst.writeAll("</div>");
            return;
        };
        try dst.print("{s}</div>", .{trim(u8, r.buffered(), " \n")});
    }

    fn leaf(r: *Reader, dst: *Writer, indent: []const u8) error{ WriteFailed, Indent }!void {
        for (indent) |c| assert(c == ' ');
        while (r.peekSentinel('\n') catch null) |until| {
            if (until.len == 0) {
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
                    if (indent.len >= 0 and until.len > new_indent + 2 and until[new_indent + 1] == ' ') {
                        try list(r, dst, local_indent);
                    } else {
                        try lineBasic(until, dst);
                        r.toss(until.len + 1);
                    }
                },
                else => {
                    try lineBasic(until, dst);
                    r.toss(until.len + 1);
                },
            }
            if (r.bufferedLen() == 0) return;
            try dst.writeByte(' ');
        }

        try lineBasic(r.take(r.bufferedLen()) catch unreachable, dst);
    }

    fn list(r: *Reader, dst: *Writer, indent: []const u8) error{ WriteFailed, Indent }!void {
        for (indent) |c| assert(c == ' ');
        try dst.writeAll("<ul>\n");
        while (r.peekSentinel('\n') catch null) |until_prefix| {
            const until = cutPrefix(u8, until_prefix, indent) orelse {
                try dst.writeAll("</ul>");
                return error.Indent;
            };
            if (until.len <= 1) {
                r.toss(until_prefix.len + 1);
                continue;
            }
            //const until = until_prefix[0 .. until_prefix.len - 1];
            var new_indent: u8 = 0;
            for (until_prefix) |chr| {
                if (chr != ' ') break;
                new_indent += 1;
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
                if (r.takeSentinel('\n')) |l| {
                    try lineBasic(trim(u8, l, "\t\n "), dst);
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

    fn multiStar(src: []const u8, index: *usize, dst: *Writer) error{WriteFailed}!void {
        var idx = index.*;
        defer index.* = idx;
        if (startsWith(u8, src[idx..], "***")) {
            if (idx + 3 < src.len and src[idx + 3] == '*') return try dst.writeByte('*');
            if (findPos(u8, src, idx + 3, "***")) |end| {
                try dst.print("<em><strong>{s}</strong></em>", .{src[idx + 3 .. end]});
                idx = end + 2;
            } else return try dst.writeByte('*');
        } else if (startsWith(u8, src[idx..], "**")) {
            if (findPos(u8, src, idx + 2, "**")) |end| {
                try dst.print("<strong>{s}</strong>", .{src[idx + 2 .. end]});
                idx = end + 1;
            } else return try dst.writeByte('*');
        } else if (startsWith(u8, src[idx..], "*")) {
            if (findPos(u8, src, idx + 1, "*")) |end| {
                if (src[end - 1] == ' ') return try dst.writeByte('*'); // Sorry about this
                try dst.print("<em>{s}</em>", .{src[idx + 1 .. end]});
                idx = end;
            } else return try dst.writeByte('*');
        }
    }

    fn lineBasic(src: []const u8, dst: *Writer) error{WriteFailed}!void {
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
                            Abx.Html{ .text = src[idx + 1 .. end] },
                        });
                        idx = end;
                    }
                },
                '*' => try multiStar(src, &idx, dst),
                '[' => {
                    if (src.len < idx + 5) {
                        try dst.writeByte('[');
                        continue;
                    }
                    if (findPos(u8, src, idx, "]")) |end| {
                        var i = idx + 1;
                        while (i < end) : (i += 1) switch (src[i]) {
                            'A'...'Z', 'a'...'z', '0'...'9', '*', '!', ' ' => continue,
                            else => break,
                        };
                        if (i != end) {
                            try dst.print("{f}", .{Abx.Html.abx(src[idx..end])});
                            idx = i;
                            continue;
                        }
                        if (src[idx + 1] == '!') {
                            const imgend = try makeImage(src[idx + 1 ..], dst, false);
                            if (imgend > 1) {
                                if (findLink(src[idx + imgend ..])) |found| {
                                    const text, const url, const link_end = found;
                                    const valid_url = validUrl(url) orelse {
                                        Abx.Html.clean(src[idx], dst) catch unreachable;
                                        continue;
                                    };
                                    idx = link_end + 3;

                                    try dst.print("<a href=\"{f}\">{f}</a>", .{
                                        Abx.Html{ .text = valid_url },
                                        Abx.Html{ .text = text },
                                    });
                                } else idx += imgend;
                            }
                        } else if (findLink(src[idx + 1 ..])) |found| {
                            const text, const url, const link_end = found;
                            const valid_url = validUrl(url) orelse {
                                Abx.Html.clean(src[idx], dst) catch unreachable;
                                continue;
                            };
                            idx += link_end + 1;
                            try dst.print("<a href=\"{f}\">{f}</a>", .{
                                Abx.Html{ .text = valid_url }, Abx.Html{ .text = text },
                            });
                        } else try dst.writeByte('[');
                    }
                },
                '!' => if (src.len > idx + 5) {
                    idx +|= try makeImage(src[idx..], dst, true);
                } else try dst.writeByte('!'),
                else => try Abx.Html.clean(src[idx], dst),
                '\r' => {},
            }
        }
    }

    pub fn makeImage(src: []const u8, w: *Writer, auto_link: bool) !usize {
        if (findLink(src[2..])) |found| {
            const text, const url, const end = found;
            const valid_url = validUrl(url) orelse {
                Abx.Html.clean(src[0], w) catch unreachable;
                return 0;
            };
            const safe_url = Abx.Html{ .text = valid_url };
            if (auto_link) {
                try w.print("<a href=\"{f}\"><img src=\"{f}\" title=\"{f}\"></a>", .{
                    safe_url, safe_url, Abx.Html{ .text = text },
                });
            } else {
                try w.print("<img src=\"{f}\" title=\"{f}\">", .{
                    safe_url, Abx.Html{ .text = text },
                });
            }
            return end + 4;
        }
        try Abx.Html.clean(src[0], w);
        return 0;
    }

    pub fn findLink(src: []const u8) ?struct { []const u8, []const u8, usize } {
        var search: usize = 1;
        while (search + 2 < src.len) : (search += 1) {
            if (findPos(u8, src, search, "](")) |mid| {
                if (src[mid - 1] == '\\') {
                    search = mid;
                    continue;
                }
                if (mid + 2 >= src.len) return null;
                if (findPos(u8, src, mid, ")")) |end| {
                    if (src[end - 1] == '\\') return null;
                    return .{ src[0..mid], src[mid + 2 .. end], end };
                }
            }
        }
        return null;
    }

    fn validUrl(src: []const u8) ?[]const u8 {
        if (findPos(u8, src, 0, "://")) |slash| {
            if (eql(u8, src[0..slash], "https")) return src;
            return null;
        }
        return src;
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
    try Translate.source(&r, &w.writer, a, std.testing.io);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "title 1" {
    const a = std.testing.allocator;
    const blob = "# Title Title Title\n";
    const expected = "<h1>Title Title Title</h1>\n";

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a, std.testing.io);
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
    try Translate.source(&r, &w.writer, a, std.testing.io);
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
    try Translate.source(&r, &w.writer, a, std.testing.io);
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
    try Translate.source(&r, &w.writer, a, std.testing.io);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "backtick" {
    const a = std.testing.allocator;
    const blob = "`backtick`";
    const expected = "<p><span class=\"coderef\">backtick</span></p>\n";

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a, std.testing.io);
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
        try Translate.source(&r, &w.writer, a, std.testing.io);
        defer w.deinit();

        try std.testing.expectEqualStrings(expected, w.written());
    }
    {
        const blob = "```backtick```";
        const expected = "<p><span class=\"coderef\"></span><span class=\"coderef\">backtick</span><span class=\"coderef\"></span></p>\n";

        var r: Reader = .fixed(blob);
        var w: Writer.Allocating = .init(a);
        try Translate.source(&r, &w.writer, a, std.testing.io);
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
    try Translate.source(&r, &w.writer, a, std.testing.io);
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
    try Translate.source(&r, &w.writer, a, std.testing.io);
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
    try Translate.source(&r, &w.writer, a, std.testing.io);
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
    try Translate.source(&r, &w.writer, a, std.testing.io);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "em3" {
    const a = std.testing.allocator;
    const blob =
        \\*hi, mom *
        \\
    ;
    const expected =
        \\<p>*hi, mom *</p>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a, std.testing.io);
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
    try Translate.source(&r, &w.writer, a, std.testing.io);
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
    try Translate.source(&r, &w.writer, a, std.testing.io);
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
    try Translate.source(&r, &w.writer, a, std.testing.io);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "link" {
    const a = std.testing.allocator;
    const blob =
        \\[link](https://this-is-the-url.com)
        \\
    ;
    const expected =
        \\<p><a href="https://this-is-the-url.com">link</a></p>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a, std.testing.io);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "fake link" {
    const a = std.testing.allocator;
    const blob =
        \\[not a link]
        \\
    ;
    const expected =
        \\<p>[not a link]</p>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a, std.testing.io);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "listed links" {
    const a = std.testing.allocator;
    const blob =
        \\ * [first](https://one.com)
        \\ * [second](https://two.com)
        \\ * [third](https://three.com)
        \\
    ;
    const expected =
        \\<p><ul>
        \\<li><a href="https://one.com">first</a></li>
        \\<li><a href="https://two.com">second</a></li>
        \\<li><a href="https://three.com">third</a></li>
        \\</ul>
        \\</p>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a, std.testing.io);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "img" {
    const a = std.testing.allocator;
    const blob =
        \\![IMG](https://this-is-the-url.com/img.png)
        \\
    ;
    const expected =
        \\<p><a href="https://this-is-the-url.com/img.png"><img src="https://this-is-the-url.com/img.png" title="IMG"></a></p>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a, std.testing.io);
    defer w.deinit();

    try std.testing.expectEqualStrings(expected, w.written());
}

test "nested img" {
    const a = std.testing.allocator;
    const blob =
        \\[![IMG](https://this-is-the-img.com/img.png)](https://this-is-the-url.com/url.html)
        \\
    ;
    const expected =
        \\<p><a href="https://this-is-the-url.com/img.png"><img src="https://this-is-the-url.com/img.png" title="IMG"></a></p>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a, std.testing.io);
    defer w.deinit();

    if (true) return error.SkipZigTest;
    try std.testing.expectEqualStrings(expected, w.written());
}

test "ref link" {
    const a = std.testing.allocator;
    const blob =
        \\[link text][ref_to_link]
        \\
        \\
        \\[ref_to_link]: https://it-was-easy-to-write-it-should-be-hard-to-parse.markdown
        \\
    ;
    const expected =
        \\<p><a href="https://it-was-easy-to-write-it-should-be-hard-to-parse.markdown">link text</a></p>
        \\
    ;

    var r: Reader = .fixed(blob);
    var w: Writer.Allocating = .init(a);
    try Translate.source(&r, &w.writer, a, std.testing.io);
    defer w.deinit();

    if (true) return error.SkipZigTest;
    try std.testing.expectEqualStrings(expected, w.written());
}

test "leaf patho-0" {
    var r: Reader = .fixed("[**Installing**](docs/INSTALL.md) **|**\n");
    var b: [260]u8 = undefined;
    var writer: Writer = .fixed(&b);
    try Translate.leaf(&r, &writer, &.{});
    try std.testing.expectEqualStrings("<a href=\"docs/INSTALL.md\">**Installing**</a> <strong>|</strong>", writer.buffered());
}

test "leaf patho-1" {
    var r: Reader = .fixed("[**Installing**](docs/INSTALL.md) **|** [**Compiling**](docs/BUILD.md) **|**\n");
    var b: [260]u8 = undefined;
    var writer: Writer = .fixed(&b);
    try Translate.leaf(&r, &writer, &.{});
    try std.testing.expectEqualStrings(
        \\<a href="docs/INSTALL.md">**Installing**</a> <strong>|</strong> <a href="docs/BUILD.md">**Compiling**</a> <strong>|</strong>
    , writer.buffered());
}

test "leaf patho-2" {
    var r: Reader = .fixed("[**Installing**](docs/INSTALL.md) **|** [**Compiling**](docs/BUILD.md) **|** [**Screenshots**](screenshots/INDEX.md) **|** [**Release Notes**](release_notes/INDEX.md) **|** [**TokTok Site**](http://toktok.github.io/) **|** [**Toxcore Spec**](https://toktok.github.io/spec)\n");
    var b: [1560]u8 = undefined;
    var writer: Writer = .fixed(&b);
    try Translate.leaf(&r, &writer, &.{});
    // TODO FIXME: very broken
    try std.testing.expectEqualStrings(
        "<a href=\"docs/INSTALL.md\">**Installing**</a> " ++
            "<strong>|</strong> <a href=\"docs/BUILD.md\">**Compiling**</a> " ++
            "<strong>|</strong> <a href=\"screenshots/INDEX.md\">**Screenshots**</a> " ++
            "<strong>|</strong> <a href=\"release_notes/INDEX.md\">**Release Notes**</a> " ++
            "<strong>|</strong> [<strong>TokTok Site</strong>](http://toktok.github.io/) " ++ // http should not resolve
            "<strong>|</strong> <a href=\"https://toktok.github.io/spec\">**Toxcore Spec**</a>",
        writer.buffered(),
    );
}

test "utox readme" {
    const input =
        \\Just like Toxcore, µTox is still alpha software, so you may encounter bugs, or maybe a crash or two. µTox also needs your help, if you do encounter any bugs or problems please [open an issue](https://github.com/uTox/uTox/issues/new).
        \\If you do not have a GitHub account, you may also [send an email](#team) directly to avoidr.
        \\
    ;
    var r: Reader = .fixed(input);
    var b: [560]u8 = undefined;
    var writer: Writer = .fixed(&b);
    try Translate.leaf(&r, &writer, &.{});
    // TODO FIXME: very broken
    try std.testing.expectEqualStrings(
        "Just like Toxcore, µTox is still alpha software, so you may encounter bugs, or maybe a crash or two. " ++
            "µTox also needs your help, if you do encounter any bugs or problems please <a href=\"https://github.com/uTox/uTox/issues/new\">open an issue</a>. " ++
            "If you do not have a GitHub account, you may also <a href=\"#team\">send an email</a> directly to avoidr.",
        writer.buffered(),
    );
}

const syntax = @import("../syntax-highlight.zig");
const Abx = @import("verse").Antibiotic;

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const eql = std.mem.eql;
const trim = std.mem.trim;
const startsWith = std.mem.startsWith;
const findScalarPos = std.mem.findScalarPos;
const findPos = std.mem.findPos;
const cutPrefix = std.mem.cutPrefix;
const assert = std.debug.assert;
