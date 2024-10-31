const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Language = enum {
    c,
    cpp,
    h,
    html,
    zig,

    pub fn toString(l: Language) ![]const u8 {
        return switch (l) {
            .c => "c",
            .cpp, .h => "cpp",
            .html => "html",
            .zig => "zig",
            //else => error.LanguageNotSupported,
        };
    }

    pub fn guessFromFilename(name: []const u8) ?Language {
        if (std.mem.endsWith(u8, name, ".zig")) {
            return .zig;
        } else if (std.mem.endsWith(u8, name, ".html")) {
            return .html;
        } else if (std.mem.endsWith(u8, name, ".h")) {
            return .cpp;
        } else if (std.mem.endsWith(u8, name, ".c")) {
            return .c;
        } else if (std.mem.endsWith(u8, name, ".cpp")) {
            return .cpp;
        }
        return null;
    }
};

pub fn highlight(a: Allocator, lang: Language, text: []const u8) ![]u8 {
    var child = std.ChildProcess.init(&[_][]const u8{
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
