index: usize,
//state: State = .{},
created: i64 = 0,
updated: i64 = 0,
repo: []const u8,
title: []const u8,
message: []const u8,
author: ?[]const u8 = null,
thread_id: usize = 0,
tags_id: usize = 0,

// state flags TODO wrap in struct?
closed: bool = false,
locked: bool = false,
embargoed: bool = false,
padding: u61 = 0,

// TODO fix when unions are supported
attach: Attach = .nos,
attach_target: usize = 0,

hash: [32]u8 = @splat(0),
thread: ?*Thread = null,

pub const Delta = @This();

pub const type_prefix = "deltas";
pub const type_version = 0;

pub const Attach = enum(u8) {
    nos = 0,
    diff = 1,
    issue = 2,
    commit = 3,
    line = 4,

    pub fn fromInt(int: u8) Attach {
        return switch (int) {
            1 => .diff,
            2 => .issue,
            3 => .commit,
            4 => .line,
            else => .nos,
        };
    }
};

const typeio = Types.readerWriter(Delta, .{
    .index = 0,
    .repo = &.{},
    .title = &.{},
    .message = &.{},
});
const writerFn = typeio.write;
const readerFn = typeio.read;

pub fn new(repo: []const u8, title: []const u8, msg: []const u8, author: []const u8) !Delta {
    const max: usize = try Types.nextIndexNamed(.deltas, repo);
    var d = Delta{
        .index = max,
        .created = std.time.timestamp(),
        .updated = std.time.timestamp(),
        .repo = repo,
        .title = title,
        .message = msg,
        .author = author,
    };

    var thread = try Thread.new(d);
    try thread.commit();
    d.thread_id = thread.index;
    return d;
}

pub fn open(a: std.mem.Allocator, repo: []const u8, index: usize) !Delta {
    const max = try Types.currentIndexNamed(.deltas, repo);
    if (index > max) return error.DeltaDoesNotExist;

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.{x}.delta", .{ repo, index });
    const file = try Types.loadData(.deltas, a, filename);
    return readerFn(file);
}

pub fn commit(delta: Delta) !void {
    if (delta.thread) |thr| thr.commit() catch {}; // Save thread as best effort

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.{x}.delta", .{ delta.repo, delta.index });
    const file = try Types.commit(.deltas, filename);
    defer file.close();
    var w_b: [2048]u8 = undefined;
    var fd_writer = file.writer(&w_b);
    try writerFn(&delta, &fd_writer.interface);
}

pub fn loadThread(delta: *Delta, a: Allocator) !*Thread {
    if (delta.thread) |thr| return thr;
    const t = try a.create(Thread);
    t.* = Thread.open(a, delta.thread_id) catch |err| t: {
        std.debug.print("Error loading thread!! {}", .{err});
        std.debug.print(" old thread_id {};", .{delta.thread_id});
        const thread = Thread.new(delta.*) catch |err2| {
            std.debug.print(" unable to create new {}\n", .{err2});
            return error.UnableToLoadThread;
        };
        std.debug.print("new thread_id {}\n", .{thread.index});
        delta.thread_id = thread.index;
        try delta.commit();
        break :t thread;
    };

    delta.thread = t;
    return t;
}

pub const Comment = struct {
    author: []const u8,
    message: []const u8,
};

pub fn addComment(delta: *Delta, a: Allocator, c: Comment) !void {
    var thread: *Thread = delta.thread orelse try delta.loadThread(a);
    try thread.addComment(a, c.author, c.message);
    thread.messages.items[thread.messages.items.len - 1].extra0 = delta.attach_target;
    try thread.commit();
    delta.updated = std.time.timestamp();
    try delta.commit();
}

pub fn addMessage(delta: *Delta, a: Allocator, m: Message) !void {
    var thread: *Thread = delta.thread orelse try delta.loadThread(a);
    try thread.addMessage(a, m);
    delta.updated = thread.updated;
    try delta.commit();
}

pub fn countComments(delta: Delta) struct { count: usize, new: bool } {
    const thread = delta.thread orelse return .{ .count = 0, .new = false };
    const ts = std.time.timestamp() - 86400;
    var cmtnew: bool = false;
    var cmtlen: usize = 0;
    for (thread.messages.items) |m| switch (m.kind) {
        .comment => {
            cmtnew = cmtnew or m.updated > ts;
            cmtlen += 1;
        },
        .diff_update => {
            cmtnew = cmtnew or m.updated > ts;
        },
    };
    return .{ .count = cmtlen, .new = cmtnew };
}

pub fn raze(_: Delta, _: std.mem.Allocator) void {
    // TODO implement raze
}

pub const Iterator = struct {
    index: usize = 0,
    last: usize = 0,
    repo: []const u8,

    pub fn init(repo: []const u8) Iterator {
        return .{
            .repo = repo,
            .last = Types.currentIndexNamed(.deltas, repo) catch 0,
        };
    }

    pub fn next(self: *Iterator, a: Allocator) ?Delta {
        while (self.index <= self.last) {
            defer self.index +|= 1;
            return open(a, self.repo, self.index) catch continue;
        }
        return null;
    }
};

pub const SearchSpecifier = enum {
    search,
    target,
    is,
    repo,
};

/// By assumption, a subject of len 0 will search across anything
pub const SearchRule = union(SearchSpecifier) {
    search: String,
    target: struct { tag: []const u8, string: String },
    is: String,
    repo: String,

    pub const String = struct {
        match: []const u8,
        inverse: bool = false,
        around: bool = false,
    };

    pub fn parse(str: []const u8) SearchRule {
        var s = str;
        std.debug.assert(s.len > 2);
        const inverse = str[0] == '-';
        if (inverse) s = s[1..];

        if (indexOf(u8, s, ":")) |i| {
            const string: String = .{ .match = s[i + 1 ..], .inverse = inverse };

            const pre: []const u8 = s[0..i];
            if (eql(u8, pre, "is")) {
                return .{ .is = string };
            } else if (eql(u8, pre, "repo")) {
                return .{ .repo = string };
            } else {
                return .{ .target = .{ .tag = pre, .string = string } };
            }
        } else {
            const string: String = .{ .match = s, .inverse = inverse };
            return .{ .search = string };
        }
    }
};

pub fn SearchIter(T: type, I: type) type {
    return struct {
        rules: []const SearchRule,

        // TODO better ABI
        iterable: I,

        const Self = @This();

        pub fn next(self: *Self, a: Allocator) ?T {
            const current = self.iterable.next(a) orelse return null;
            if (self.evalRules(current)) {
                return current;
            }
            return self.next(a);
        }

        fn evalRules(self: Self, target: T) bool {
            for (self.rules) |rule| {
                if (!self.eval(rule, target)) return false;
            } else return true;
        }

        /// TODO: I think this function might overrun for some inputs
        /// TODO: add support for int types
        fn eval(_: Self, rule: SearchRule, target: T) bool {
            if (comptime std.meta.hasMethod(T, "searchEval")) {
                return target.searchEval(rule);
            }

            switch (rule) {
                .is => |is| {
                    if (eql(u8, is.match, "diff")) {
                        if (target.attach == .diff) return true;
                    } else if (eql(u8, is.match, "issue")) {
                        if (target.attach == .issue) return true;
                    } else {
                        if (target.attach == .nos) return true;
                    }
                    return false;
                },
                .repo => |repo| return eql(u8, repo.match, target.repo),
                .target => |trgt| {
                    inline for (comptime std.meta.fieldNames(T)) |name| {
                        if (eql(u8, trgt.tag, name)) {
                            if (@TypeOf(@field(target, name)) == []const u8) {
                                if (indexOf(u8, @field(target, name), trgt.string.match)) |_| {
                                    return true;
                                }
                            }
                        }
                    }
                    return false;
                },
                .search => |any| {
                    inline for (comptime std.meta.fieldNames(T)) |name| {
                        if (@TypeOf(@field(target, name)) == []const u8) {
                            if (indexOf(u8, @field(target, name), any.match)) |_| {
                                return true;
                            }
                        }
                    }
                    return false;
                },
            }
        }

        pub fn raze(_: Self) void {}
    };
}

pub const AnyIterator = struct {
    dir: std.fs.Dir.Iterator,

    pub fn init() AnyIterator {
        return .{
            .dir = (Types.iterableDir(.deltas) catch unreachable).iterate(),
        };
    }

    pub fn next(self: *AnyIterator, a: Allocator) ?Delta {
        const line = (self.dir.next() catch return null) orelse return null;
        if (line.kind != .file) return self.next(a);
        if (!std.mem.endsWith(u8, line.name, ".delta")) return self.next(a);
        const name = line.name[0 .. line.name.len - 6];
        const i = lastIndexOf(u8, name, ".") orelse return self.next(a);
        const num = parseInt(usize, name[i + 1 ..], 16) catch return self.next(a);
        const current = open(a, name[0..i], num) catch return self.next(a);

        return current;
    }
};

pub fn searchAny(rules: []const SearchRule) SearchIter(Delta, AnyIterator) {
    return .{
        .rules = rules,
        .iterable = .init(),
    };
}

pub fn searchRepo(repo: []const u8, rules: []const SearchRule) SearchIter(Delta, Iterator) {
    return .{
        .rules = rules,
        .iterable = .init(repo),
    };
}

test Delta {
    const a = std.testing.allocator;
    var tempdir = std.testing.tmpDir(.{});
    defer tempdir.cleanup();
    try Types.init(try tempdir.dir.makeOpenPath("delta", .{ .iterate = true }));

    var d = try Delta.new("repo_name", "title", "message", "author");

    // LOL, you thought
    const mask: i64 = ~@as(i64, 0xffffff);
    d.created = std.time.timestamp() & mask;
    d.updated = std.time.timestamp() & mask;

    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();
    try writerFn(&d, &writer.writer);

    const v1_text: []const u8 =
        \\# deltas/0
        \\index: 1
        \\created: 1744830464
        \\updated: 1744830464
        \\repo: repo_name
        \\title: title
        \\message: message
        \\author: author
        \\thread_id: 1
        \\tags_id: 0
        \\closed: false
        \\locked: false
        \\embargoed: false
        \\attach: nos
        \\attach_target: 0
        \\hash: 0000000000000000000000000000000000000000000000000000000000000000
        \\
        \\
    ;

    try std.testing.expectEqualStrings(v1_text, writer.written());
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const lastIndexOf = std.mem.lastIndexOf;
const indexOf = std.mem.indexOf;
const eql = std.mem.eql;
const parseInt = std.fmt.parseInt;
const endian = builtin.cpu.arch.endian();
const AnyReader = std.io.AnyReader;

const Types = @import("../types.zig");
const Thread = Types.Thread;
const Message = Types.Message;
