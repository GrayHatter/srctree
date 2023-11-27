const std = @import("std");

pub const Bleach = @This();

pub const Error = error{
    NoSpaceLeft,
    OutOfMemory,
};

pub const Rules = enum {
    html,
};

pub const Options = struct {
    target: Rules = .html,
    skip_chars: ?[]const u8 = null,
    // when true, sanitizer functions will return an error instead of replacing the char.
    error_on_replace: bool = false,
};

pub fn sanitizeAlloc(a: std.mem.Allocator, in: []const u8, opts: Options) Error![]u8 {
    const func = switch (opts.target) {
        .html => sanitizeHtmlChar,
    };

    var out_size: usize = 0;
    for (in) |c| out_size +|= try func(c, null);
    var out = try a.alloc(u8, out_size);
    return try sanitize(in, out, opts);
}

// if an error is encountered, state of out is undefined
pub fn sanitize(in: []const u8, out: []u8, opts: Options) Error![]u8 {
    const func = switch (opts.target) {
        .html => sanitizeHtmlChar,
    };

    var pos: usize = 0;
    for (in) |src| {
        const count = try func(src, out[pos..]);
        pos += count;
    }
    return out[0..pos];
}

fn StreamSanitizer(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        pub const StreamError = ReaderType.Error || Error;

        alloc: std.mem.Allocator,
        src_reader: ReaderType,
        src_opts: Options,

        fn init(a: std.mem.Allocator, reader: ReaderType, opts: Options) !Self {
            return Self{
                .alloc = a,
                .src_reader = reader,
                .src_opts = opts,
            };
        }

        pub fn raze(_: *Self) void {}

        pub fn read(self: *Self, buffer: []u8) StreamError!usize {
            _ = self;
            _ = buffer;
            return 0;
        }
    };
}

pub fn sanitizeStream(a: std.mem.Allocator, reader: anytype, opts: Options) !StreamSanitizer {
    return StreamSanitizer(@TypeOf(reader)).init(a, reader, opts);
}

fn sanitizeHtmlChar(in: u8, out: ?[]u8) Error!usize {
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
