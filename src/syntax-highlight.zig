pub const Markdown = @import("syntax/markdown.zig");

pub const Language = enum {
    bash,
    c,
    cpp,
    css,
    h,
    html,
    ini,
    kotlin,
    lua,
    markdown,
    nginx,
    python,
    sh,
    txt,
    vim,
    zig,

    pub fn toString(l: Language) ![]const u8 {
        return switch (l) {
            .bash, .sh => "sh",
            .c => "c",
            .cpp, .h => "cpp",
            .css => "css",
            .html => "html",
            .ini => "ini",
            .kotlin => "kotlin",
            .lua => "lua",
            .markdown => "markdown",
            .nginx => "nginx",
            .python => "python",
            .txt => "txt",
            .vim => @tagName(l),
            .zig => "zig",
            //else => error.LanguageNotSupported,
        };
    }

    pub fn fromString(str: []const u8) ?Language {
        return std.meta.stringToEnum(Language, str);
    }

    pub fn guessFromFilename(name: []const u8) ?Language {
        if (endsWith(u8, name, ".bash") or endsWith(u8, name, ".sh")) {
            return .sh;
        } else if (endsWith(u8, name, ".c")) {
            return .c;
        } else if (endsWith(u8, name, ".h") or endsWith(u8, name, ".cpp")) {
            return .cpp;
        } else if (endsWith(u8, name, ".css")) {
            return .css;
        } else if (endsWith(u8, name, ".html")) {
            return .html;
        } else if (endsWith(u8, name, ".kotlin") or endsWith(u8, name, ".kt")) {
            return .kotlin;
        } else if (endsWith(u8, name, ".ini") or
            endsWith(u8, name, ".cfg") or
            endsWith(u8, name, ".conf") or
            endsWith(u8, name, ".config") or
            endsWith(u8, name, ".editorconfig"))
        {
            return .ini;
        } else if (endsWith(u8, name, ".lua")) {
            return .lua;
        } else if (endsWith(u8, name, ".md") or
            endsWith(u8, name, ".markdown"))
        {
            return .markdown;
        } else if (eql(u8, name, "nginx.conf")) {
            return .nginx;
        } else if (endsWith(u8, name, ".py") or
            endsWith(u8, name, ".bzl") or
            endsWith(u8, name, ".bazel") or
            eql(u8, name, "BUCK") or
            eql(u8, name, "BUILD") or
            eql(u8, name, "WORKSPACE"))
        {
            return .python;
        } else if (endsWith(u8, name, ".vim") or eql(u8, name, ".vimrc")) {
            return .vim;
        } else if (endsWith(u8, name, ".zig")) {
            return .zig;
        }

        return null;
    }
};

pub fn translate(r: *Reader, w: Writer, lang: Language, a: Allocator) !void {
    return switch (lang) {
        .bash,
        .c,
        .cpp,
        .css,
        .h,
        .html,
        .ini,
        .kotlin,
        .lua,
        .nginx,
        .python,
        .sh,
        .txt,
        .vim,
        .zig,
        => return error.NotSupported,
        .markdown => translateInternal(r, w, lang, a),
    };
}

pub fn translateInternal(r: *Reader, w: Writer, lang: Language, a: Allocator) !void {
    return switch (lang) {
        .markdown => try Markdown.translate(r, w, a),
        else => unreachable,
    };
}

pub const HighlightError = error{
    AccessDenied,
    Canceled,
    EndOfStream,
    InsufficentResources,
    InvalidParam,
    OutOfMemory,
    ReadFailed,
    Unexpected,
    WouldBlock,
    WriteFailed,
};

pub fn highlight(lang: Language, text: []const u8, a: Allocator, io: Io) HighlightError![]u8 {
    return switch (lang) {
        .bash,
        .c,
        .cpp,
        .css,
        .h,
        .html,
        .ini,
        .kotlin,
        .lua,
        .markdown,
        .nginx,
        .python,
        .sh,
        .txt,
        .vim,
        => highlightPygmentize(lang, text, a, io) catch |err| switch (err) {
            error.EndOfStream => error.EndOfStream,
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            error.WriteFailed => error.WriteFailed,
            error.WouldBlock => error.WouldBlock,
            error.Unexpected => error.Unexpected,
            error.ReadFailed => error.ReadFailed,
            error.AntivirusInterference,
            error.FileLocksUnsupported,
            error.OperationUnsupported,
            error.ProcessAlreadyExec,
            => error.Unexpected,
            error.PermissionDenied,
            error.AccessDenied,
            error.FileSystem,
            => error.AccessDenied,
            error.FileTooBig,
            error.NoSpaceLeft,
            error.DeviceBusy,
            error.NoDevice,
            error.FileBusy,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SystemResources,
            error.ResourceLimitReached,
            => error.InsufficentResources,
            error.FileNotFound,
            error.NotDir,
            error.SymLinkLoop,
            error.ReadOnlyFileSystem,
            error.NetworkNotFound,
            error.NameTooLong,
            error.BadPathName,
            error.PipeBusy,
            error.IsDir,
            error.UnrecognizedVolume,
            error.PathAlreadyExists,
            error.InvalidUserId,
            error.InvalidProcessGroupId,
            error.InvalidName,
            error.InvalidWtf8,
            error.InvalidExe,
            error.InvalidBatchScriptArg,
            => error.InvalidParam,
        },
        .zig => {
            const zerod = try a.dupeSentinel(u8, text, 0);
            return highlightInternal(lang, zerod, a) catch unreachable;
        },
    };
}

fn wrap(comptime class: []const u8, text: []const u8, out: *Writer) !void {
    try out.writeAll("<span class=\"" ++ class ++ "\">");
    try appendEscaped(out, text);
    try out.writeAll("</span>");
}

pub fn highlightInternal(lang: Language, text: [:0]const u8, a: Allocator) ![]u8 {
    switch (lang) {
        .zig => {
            const ast = std.zig.Ast.parse(a, text, .zig) catch unreachable;

            var out_w: Writer.Allocating = .init(a);
            const out = &out_w.writer;

            const root_node = ast.tokenStart(0);
            const start_token: u32 = ast.firstToken(@enumFromInt(root_node));
            const end_token = ast.lastToken(@enumFromInt(root_node)) + 1;

            var cursor: usize = ast.tokenStart(start_token);

            var indent: usize = 0;
            if (findLast(u8, ast.source[0..cursor], "\n")) |newline_index| {
                for (ast.source[newline_index + 1 .. cursor]) |c| {
                    if (c == ' ') indent += 1 else break;
                }
            }

            //var next_annotate_index: usize = 0;
            //var token_parents: std.array_hash_map.Auto(std.zig.Ast.TokenIndex, std.zig.Ast.Node.Index) = .empty;
            //var pre: Writer.Allocating = .init(a);
            //var field_access_buffer: *Writer = &pre.writer;
            const tags, const starts = .{
                ast.tokens.items(.tag)[start_token..end_token],
                ast.tokens.items(.start)[start_token..end_token],
            };

            for (tags, starts, start_token..) |tag, start, token_index2| {
                const token_index: u32 = @intCast(token_index2);
                const between = ast.source[cursor..start];
                if (std.mem.trim(u8, between, " \t\r\n").len > 0) {
                    try out.writeAll("<span class=\"c1\">");
                    try appendUnindented(out, between, indent);
                    try out.writeAll("</span>");
                } else if (between.len > 0) {
                    try appendUnindented(out, between, indent);
                }
                if (tag == .eof) break;
                const slice = ast.tokenSlice(token_index);
                cursor = start + slice.len;

                switch (tag) {
                    .eof => unreachable,

                    .keyword_addrspace,
                    .keyword_align,
                    .keyword_and,
                    .keyword_asm,
                    .keyword_break,
                    .keyword_catch,
                    .keyword_comptime,
                    .keyword_const,
                    .keyword_continue,
                    .keyword_defer,
                    .keyword_else,
                    .keyword_enum,
                    .keyword_errdefer,
                    .keyword_error,
                    .keyword_export,
                    .keyword_extern,
                    .keyword_for,
                    .keyword_if,
                    .keyword_inline,
                    .keyword_noalias,
                    .keyword_noinline,
                    .keyword_nosuspend,
                    .keyword_opaque,
                    .keyword_or,
                    .keyword_orelse,
                    .keyword_packed,
                    .keyword_anyframe,
                    .keyword_pub,
                    .keyword_resume,
                    .keyword_return,
                    .keyword_linksection,
                    .keyword_callconv,
                    .keyword_struct,
                    .keyword_suspend,
                    .keyword_switch,
                    .keyword_test,
                    .keyword_threadlocal,
                    .keyword_try,
                    .keyword_union,
                    .keyword_unreachable,
                    .keyword_var,
                    .keyword_volatile,
                    .keyword_allowzero,
                    .keyword_while,
                    .keyword_anytype,
                    .keyword_fn,
                    => try wrap("kr", slice, out),
                    .string_literal, .char_literal => try wrap("sh", slice, out),
                    .multiline_string_literal_line => try wrap("sh", slice, out),
                    .builtin => try wrap("nb", slice, out),
                    .doc_comment, .container_doc_comment => try wrap("c1", slice, out),
                    .identifier => if (token_index > 0 and ast.tokenTag(token_index - 1) == .keyword_fn) {
                        try wrap("fn", slice, out);
                    } else if (isPrimitiveNonType(slice)) {
                        try wrap("null", slice, out);
                    } else if (std.zig.primitives.isPrimitive(slice)) {
                        try wrap("type", slice, out);
                    } else try appendEscaped(out, slice),
                    .number_literal => try wrap("mr", slice, out),
                    .bang,
                    .pipe,
                    .pipe_pipe,
                    .pipe_equal,
                    .equal,
                    .equal_equal,
                    .equal_angle_bracket_right,
                    .bang_equal,
                    .l_paren,
                    .r_paren,
                    .semicolon,
                    .percent,
                    .percent_equal,
                    .l_brace,
                    .r_brace,
                    .l_bracket,
                    .r_bracket,
                    .period,
                    .period_asterisk,
                    .ellipsis2,
                    .ellipsis3,
                    .caret,
                    .caret_equal,
                    .plus,
                    .plus_plus,
                    .plus_equal,
                    .plus_percent,
                    .plus_percent_equal,
                    .plus_pipe,
                    .plus_pipe_equal,
                    .minus,
                    .minus_equal,
                    .minus_percent,
                    .minus_percent_equal,
                    .minus_pipe,
                    .minus_pipe_equal,
                    .asterisk,
                    .asterisk_equal,
                    .asterisk_percent,
                    .asterisk_percent_equal,
                    .asterisk_pipe,
                    .asterisk_pipe_equal,
                    .asterisk_asterisk,
                    .arrow,
                    .colon,
                    .slash,
                    .slash_equal,
                    .comma,
                    .ampersand,
                    .ampersand_equal,
                    .question_mark,
                    .angle_bracket_left,
                    .angle_bracket_left_equal,
                    .angle_bracket_angle_bracket_left,
                    .angle_bracket_angle_bracket_left_equal,
                    .angle_bracket_angle_bracket_left_pipe,
                    .angle_bracket_angle_bracket_left_pipe_equal,
                    .angle_bracket_right,
                    .angle_bracket_right_equal,
                    .angle_bracket_angle_bracket_right,
                    .angle_bracket_angle_bracket_right_equal,
                    .tilde,
                    => try appendEscaped(out, slice),
                    .invalid_periodasterisks, .invalid => return error.InvalidToken,
                }
            }
            const output = try out_w.toOwnedSlice();
            return output;
        },
        else => unreachable,
    }
}

fn walkFieldAccesses(
    ast: *const std.zig.Ast,
    file_index: enum(u32) { _ },
    out: *Writer,
    node: std.zig.Ast.Node.Index,
) !void {
    //const ast = file_index.get_ast();
    const object_node, const field_ident = ast.nodeData(node).node_and_token;
    switch (ast.nodeTag(object_node)) {
        .identifier => {
            //const lhs_ident = ast.nodeMainToken(object_node);
            //try resolveIdentLink(file_index, out, lhs_ident);
        },
        .field_access => try walkFieldAccesses(ast, file_index, out, object_node),
        else => {},
    }
    if (out.buffered().len > 0) {
        try out.writeByte('.');
        try out.writeAll(ast.tokenSlice(field_ident));
    }
}

pub fn isPrimitiveNonType(name: []const u8) bool {
    return eql(u8, name, "undefined") or
        eql(u8, name, "null") or
        eql(u8, name, "true") or
        eql(u8, name, "false");
}

fn appendUnindented(out: *Writer, s: []const u8, indent: usize) !void {
    var it = std.mem.splitScalar(u8, s, '\n');
    var is_first_line = true;
    while (it.next()) |line| {
        if (is_first_line) {
            try appendEscaped(out, line);
            is_first_line = false;
        } else {
            try out.writeByte('\n');
            try appendEscaped(out, unindent(line, indent));
        }
    }
}

pub fn unindent(line: []const u8, c: usize) []const u8 {
    return line[c..];
}

pub fn appendEscaped(out: *Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try out.writeAll("&amp;"),
            '<' => try out.writeAll("&lt;"),
            '>' => try out.writeAll("&gt;"),
            '"' => try out.writeAll("&quot;"),
            else => try out.writeByte(c),
        }
    }
}

test "highlight zig" {
    if (true) return error.SkipZigTest; // leaks
    const this = @embedFile("syntax-highlight.zig");
    _ = try highlightInternal(.zig, this, std.testing.allocator);
}

// Duplicated from stdlib processSpawn
// TODO We can reduce the set of errors we return here
pub const PygmentizeError = error{
    WriteFailed,
    Canceled,
    SystemResources,
    IsDir,
    WouldBlock,
    AccessDenied,
    Unexpected,
    EndOfStream,
    FileTooBig,
    NoSpaceLeft,
    DeviceBusy,
    PermissionDenied,
    NoDevice,
    FileBusy,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    PathAlreadyExists,
    SymLinkLoop,
    FileNotFound,
    NotDir,
    ReadOnlyFileSystem,
    NetworkNotFound,
    NameTooLong,
    BadPathName,
    PipeBusy,
    AntivirusInterference,
    FileLocksUnsupported,
    OperationUnsupported,
    FileSystem,
    UnrecognizedVolume,
    ReadFailed,
    OutOfMemory,
    InvalidWtf8,
    InvalidExe,
    InvalidBatchScriptArg,
    ResourceLimitReached,
    InvalidUserId,
    InvalidProcessGroupId,
    InvalidName,
    ProcessAlreadyExec,
};

pub fn highlightPygmentize(lang: Language, text: []const u8, a: Allocator, io: Io) PygmentizeError![]u8 {
    var child = try std.process.spawn(io, .{
        .argv = &[_][]const u8{ "pygmentize", "-f", "html", "-l", try lang.toString() },
        .expand_arg0 = .no_expand,
        .environ_map = &.init(a),
        .cwd = .inherit,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    var stdout: Writer.Allocating = try .initCapacity(a, text.len * 2);
    errdefer stdout.deinit();

    if (child.stdin) |cstdin| {
        var writer = cstdin.writer(io, &.{});
        try writer.interface.writeAll(text);
        cstdin.close(io);
        child.stdin = null;
    }

    defer if (child.stdout) |out| out.close(io);

    var r_b: [8196]u8 = undefined;
    var outr = child.stdout.?.reader(io, &r_b);
    // We just assume the prefix doesn't change
    try outr.interface.fill(28);
    outr.interface.toss(28);
    while (outr.interface.stream(&stdout.writer, .limited(0x800000))) |_| {
        // continue until we hit EOS
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => log.err("err {}", .{err}),
    }

    _ = try child.wait(io);
    if (endsWith(u8, stdout.writer.buffer[0..stdout.writer.end], "</pre></div>\n"))
        stdout.writer.end -|= 13;

    return try stdout.toOwnedSlice();
}
const log = std.log.scoped(.bleh);

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const endsWith = std.mem.endsWith;
const startsWith = std.mem.startsWith;
const eql = std.mem.eql;
const findLast = std.mem.findLast;
