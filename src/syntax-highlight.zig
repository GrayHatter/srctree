pub const Markdown = @import("syntax/markdown.zig");

pub const Language = enum {
    c,
    cpp,
    h,
    html,
    ini,
    kotlin,
    lua,
    markdown,
    nginx,
    python,
    vim,
    zig,

    pub fn toString(l: Language) ![]const u8 {
        return switch (l) {
            .c => "c",
            .cpp, .h => "cpp",
            .html => "html",
            .ini => "ini",
            .kotlin => "kotlin",
            .lua => "lua",
            .markdown => "markdown",
            .nginx => "nginx",
            .python => "python",
            .vim => @tagName(l),
            .zig => "zig",
            //else => error.LanguageNotSupported,
        };
    }

    pub fn fromString(str: []const u8) ?Language {
        return std.meta.stringToEnum(Language, str);
    }

    pub fn guessFromFilename(name: []const u8) ?Language {
        if (endsWith(u8, name, ".c")) {
            return .c;
        } else if (endsWith(u8, name, ".h") or endsWith(u8, name, ".cpp")) {
            return .cpp;
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

pub fn translate(a: Allocator, lang: Language, text: []const u8) ![]u8 {
    return switch (lang) {
        .c,
        .cpp,
        .h,
        .html,
        .ini,
        .kotlin,
        .lua,
        .nginx,
        .python,
        .vim,
        .zig,
        => return error.NotSupported,
        .markdown => translateInternal(a, lang, text),
    };
}

pub fn translateInternal(a: Allocator, lang: Language, text: []const u8) ![]u8 {
    return switch (lang) {
        .markdown => try Markdown.translate(a, text),
        else => unreachable,
    };
}

pub fn highlight(a: Allocator, lang: Language, text: []const u8) ![]u8 {
    return switch (lang) {
        .c,
        .cpp,
        .h,
        .html,
        .ini,
        .kotlin,
        .lua,
        .markdown,
        .nginx,
        .python,
        .vim,
        .zig,
        => highlightPygmentize(a, lang, text),
        //else => highlightInternal(a, lang, text),

    };
}

pub fn highlightInternal(a: Allocator, lang: Language, text: []const u8) ![]u8 {
    _ = a;
    _ = lang;
    _ = text;
    comptime unreachable;
}

pub fn highlightPygmentize(a: Allocator, lang: Language, text: []const u8) ![]u8 {
    var child = std.process.Child.init(&[_][]const u8{
        "pygmentize",
        "-f",
        "html",
        "-l",
        try lang.toString(),
    }, a);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.expand_arg0 = .no_expand;
    child.spawn() catch unreachable;

    const err_mask = std.posix.POLL.ERR | std.posix.POLL.NVAL | std.posix.POLL.HUP;
    var poll_fd = [_]std.posix.pollfd{
        .{
            .fd = child.stdout.?.handle,
            .events = std.posix.POLL.IN,
            .revents = undefined,
        },
    };
    _ = std.posix.write(child.stdin.?.handle, text) catch unreachable;
    std.posix.close(child.stdin.?.handle);
    child.stdin = null;
    var buf = std.ArrayList(u8).init(a);
    const abuf = try a.alloc(u8, 0xffffff);
    while (true) {
        const events_len = std.posix.poll(&poll_fd, std.math.maxInt(i32)) catch unreachable;
        if (events_len == 0) continue;
        if (poll_fd[0].revents & std.posix.POLL.IN != 0) {
            const amt = std.posix.read(poll_fd[0].fd, abuf) catch unreachable;
            if (amt == 0) break;
            try buf.appendSlice(abuf[0..amt]);
        } else if (poll_fd[0].revents & err_mask != 0) {
            break;
        }
    }
    a.free(abuf);

    _ = child.wait() catch unreachable;
    return try buf.toOwnedSlice();
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const endsWith = std.mem.endsWith;
const eql = std.mem.eql;
