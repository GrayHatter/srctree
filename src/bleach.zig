const std = @import("std");

pub const Bleach = @This();

pub const Error = error{
    NoSpaceLeft,
    OutOfMemory,
};

pub const Rules = enum {
    html,
    title,
    filename,

    pub fn func(r: Rules) RuleFn {
        return switch (r) {
            .html => bleachHtml,
            .title => bleachHtml,
            .filename => bleachFilename,
        };
    }
};

pub const RuleFn = *const fn (u8, ?[]u8) Error!usize;

pub const Options = struct {
    rules: Rules = .html,
    skip_chars: ?[]const u8 = null,
    // when true, sanitizer functions will return an error instead of replacing the char.
    error_on_replace: bool = false,
};

pub fn sanitizeAlloc(a: std.mem.Allocator, in: []const u8, opts: Options) Error![]u8 {
    const func = opts.rules.func();

    var out_size: usize = 0;
    for (in) |c| out_size +|= try func(c, null);
    const out = try a.alloc(u8, out_size);
    return try sanitize(in, out, opts);
}

pub fn streamSanitizer(src: anytype, opts: Options) StreamSanitizer(@TypeOf(src)) {
    return StreamSanitizer(@TypeOf(src)).init(src, opts);
}

/// if an error is encountered, `out` is undefined
pub fn sanitize(in: []const u8, out: []u8, opts: Options) Error![]u8 {
    const func = opts.rules.func();

    var pos: usize = 0;
    for (in) |src| {
        const count = try func(src, out[pos..]);
        pos += count;
    }
    return out[0..pos];
}

pub fn StreamSanitizer(comptime Source: type) type {
    return struct {
        const Self = @This();

        index: usize,
        src: Source,
        src_opts: Options,
        sanitizer: RuleFn,

        fn init(src: Source, opts: Options) Self {
            return Self{
                .index = 0,
                .src = src,
                .src_opts = opts,
                .sanitizer = opts.rules.func(),
            };
        }

        pub fn raze(_: *Self) void {}

        pub fn any(self: *const Self) std.io.AnyReader {
            return .{
                .context = @ptrCast(*self.context),
                .readFn = typeErasedReadFn,
            };
        }

        pub fn typeErasedReadFn(context: *const anyopaque, buffer: []u8) anyerror!usize {
            const ptr: *const Source = @alignCast(@ptrCast(context));
            return read(ptr.*, buffer);
        }

        pub fn read(self: *Self, buffer: []u8) Error!usize {
            const count = try self.sanitizer(self.src[self.index..], buffer);
            self.index += count;
            return count;
        }
    };
}

fn bleachFilename(in: u8, out: ?[]u8) Error!usize {
    var same = [1:0]u8{in};
    const replace = switch (in) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => &same,
        ' ', '.' => "-",
        '\n', '\t' => "",
        else => "",
    };
    if (out) |o| {
        if (replace.len > o.len) return error.NoSpaceLeft;
        @memcpy(o[0..replace.len], replace);
    }
    return replace.len;
}

fn bleachHtml(in: u8, out: ?[]u8) Error!usize {
    var same = [1:0]u8{in};
    const replace = switch (in) {
        '<' => "&lt;",
        '&' => "&amp;",
        '>' => "&gt;",
        '"' => "&quot;",
        else => &same,
    };
    if (out) |o| {
        std.debug.assert(o.len > 0);
        if (replace.len > o.len) return error.NoSpaceLeft;
        @memcpy(o[0..replace.len], replace);
    }
    return replace.len;
}

test bleachFilename {
    var a = std.testing.allocator;

    const allowed = "this-filename-is-allowed";
    const not_allowed = "this-file\nname is !really! me$$ed up?";

    var output = try sanitizeAlloc(a, allowed, .{ .rules = .filename });
    try std.testing.expectEqualStrings(allowed, output);
    a.free(output);

    output = try sanitizeAlloc(a, not_allowed, .{ .rules = .filename });
    try std.testing.expectEqualStrings("this-filename-is-really-meed-up", output);
    a.free(output);
}
