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
        .zig,
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
        //else => highlightInternal(a, lang, text),

    };
}

pub fn highlightInternal(a: Allocator, lang: Language, text: []const u8) ![]u8 {
    _ = a;
    _ = lang;
    _ = text;
    comptime unreachable;
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
