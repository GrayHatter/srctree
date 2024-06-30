const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const endian = builtin.cpu.arch.endian();

const Bleach = @import("../bleach.zig");
const Types = @import("../types.zig");
const Comment = Types.Comment;
const Thread = Types.Thread;
const Template = @import("../template.zig");

pub const Delta = @This();

const DELTA_VERSION: usize = 0;
pub const TYPE_PREFIX = "{s}/deltas";
pub var datad: Types.TypeStorage = undefined;

pub fn initType() !void {}

fn readVersioned(a: Allocator, idx: usize, file: std.fs.File) !Delta {
    var reader = file.reader();
    const ver: usize = try reader.readInt(usize, endian);
    return switch (ver) {
        0 => Delta{
            .index = idx,
            .file = file,
            .state = try reader.readStruct(Thread.State),
            .created = try reader.readInt(i64, endian),
            .updated = try reader.readInt(i64, endian),
            .repo = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .title = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .message = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            //.author = try reader.readUntilDelimiterAlloc(a, 0, 0xFFFF),
            .author = "",
            .thread_id = try reader.readInt(usize, endian),
            .attach = switch (Attach.fromInt(try reader.readInt(u8, endian))) {
                .nos => .{ .nos = try reader.readInt(usize, endian) },
                .diff => .{ .diff = try reader.readInt(usize, endian) },
                .issue => .{ .issue = try reader.readInt(usize, endian) },
                .commit => .{ .issue = try reader.readInt(usize, endian) },
                .line => .{ .issue = try reader.readInt(usize, endian) },
            },
            .tags_id = try reader.readInt(usize, endian),
        },
        else => return error.UnsupportedVersion,
    };
}

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

index: usize,
state: Thread.State = .{},
created: i64 = 0,
updated: i64 = 0,
repo: []const u8,
title: []const u8,
message: []const u8,
author: []const u8 = "",
thread_id: usize = 0,
tags_id: usize = 0,

attach: union(Attach) {
    nos: usize,
    diff: usize,
    issue: usize,
    commit: usize,
    line: usize,
} = .{ .nos = 0 },
hash: [32]u8 = [_]u8{0} ** 32,
thread: ?*Thread = null,
file: std.fs.File,

pub fn writeOut(self: Delta) !void {
    try self.file.seekTo(0);
    var writer = self.file.writer();
    try writer.writeInt(usize, DELTA_VERSION, endian);
    try writer.writeStruct(self.state);
    try writer.writeInt(i64, self.created, endian);
    try writer.writeInt(i64, self.updated, endian);
    try writer.writeAll(self.repo);
    try writer.writeAll("\x00");
    try writer.writeAll(self.title);
    try writer.writeAll("\x00");
    try writer.writeAll(self.message);
    try writer.writeAll("\x00");
    //try writer.writeAll(self.author);
    //try writer.writeAll("\x00");
    try writer.writeInt(usize, self.thread_id, endian);

    try writer.writeInt(u8, @intFromEnum(self.attach), endian);
    switch (self.attach) {
        .nos => |att| try writer.writeInt(usize, att, endian),
        .diff => |att| try writer.writeInt(usize, att, endian),
        .issue => |att| try writer.writeInt(usize, att, endian),
        .commit => |att| try writer.writeInt(usize, att, endian),
        .line => |att| try writer.writeInt(usize, att, endian),
    }
    try writer.writeInt(usize, self.tags_id, endian);
    // FIXME write 32 not a maybe
    if (self.thread) |thread| {
        try writer.writeAll(&thread.hash);
    }

    try writer.writeAll("\x00");
    try self.file.setEndPos(self.file.getPos() catch unreachable);

    if (self.thread) |t| try t.writeOut();
}

pub fn readFile(a: std.mem.Allocator, idx: usize, file: std.fs.File) !Delta {
    const delta: Delta = try readVersioned(a, idx, file);
    return delta;
}

pub fn loadThread(self: *Delta, a: Allocator) !*const Thread {
    if (self.thread != null) return error.MemoryAlreadyLoaded;
    const t = try a.create(Thread);
    t.* = try Thread.open(a, self.thread_id) orelse return error.UnableToLoadThread;
    self.thread = t;
    return t;
}

pub fn getComments(self: *Delta, a: Allocator) ![]Comment {
    if (self.thread) |thread| {
        return thread.getComments(a);
    }
    return error.ThreadNotLoaded;
}

pub fn addComment(self: *Delta, a: Allocator, c: Comment) !void {
    if (self.thread) |thread| {
        return thread.addComment(a, c);
    }
    return error.ThreadNotLoaded;
}

pub fn builder(self: Delta) Template.Context.Builder(Delta) {
    return Template.Context.Builder(Delta).init(self);
}

pub fn contextBuilder(self: Delta, a: Allocator, ctx: *Template.Context) !void {
    try ctx.put("Title", try Bleach.sanitizeAlloc(a, self.title, .{}));
    try ctx.put("Desc", try Bleach.sanitizeAlloc(a, self.message, .{}));

    try ctx.put("Index", try std.fmt.allocPrint(a, "0x{x}", .{self.index}));
    try ctx.put("Title_uri", try std.fmt.allocPrint(
        a,
        "/repo/{s}/{s}/{x}",
        .{
            self.repo,
            if (self.attach == .issue) "issues" else "diffs",
            self.index,
        },
    ));
}

pub fn raze(self: Delta, _: std.mem.Allocator) void {
    //if (self.alloc_data) |data| {
    //    a.free(data);
    //}
    self.file.close();
}

fn currMaxSet(repo: []const u8, count: usize) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "_{s}_count", .{repo});
    var cnt_file = try datad.createFile(filename, .{});
    defer cnt_file.close();
    var writer = cnt_file.writer();
    _ = try writer.writeInt(usize, count, endian);
}

fn currMax(repo: []const u8) !usize {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "_{s}_count", .{repo});
    var cnt_file = try datad.openFile(filename, .{ .mode = .read_write });
    defer cnt_file.close();
    var reader = cnt_file.reader();
    const count: usize = try reader.readInt(usize, endian);
    return count;
}

pub const Iterator = struct {
    alloc: Allocator,
    index: usize = 0,
    last: usize = 0,
    repo: []const u8,

    pub fn next(self: *Iterator) ?Delta {
        var buf: [2048]u8 = undefined;
        while (self.index <= self.last) {
            defer self.index +|= 1;
            const filename = std.fmt.bufPrint(&buf, "{s}.{x}.delta", .{ self.repo, self.index }) catch unreachable;
            const file = datad.openFile(filename, .{ .mode = .read_only }) catch continue;
            return Delta.readFile(self.alloc, self.index, file) catch continue;
        }
        return null;
    }
};

pub fn iterator(a: Allocator, repo: []const u8) Iterator {
    return .{
        .alloc = a,
        .repo = repo,
        .last = last(repo),
    };
}

pub fn last(repo: []const u8) usize {
    return currMax(repo) catch 0;
}

pub fn new(repo: []const u8) !Delta {
    // TODO this is probably a bug
    const max: usize = currMax(repo) catch 0;
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}.{x}.delta", .{ repo, max + 1 });
    const file = try datad.createFile(filename, .{});
    try currMaxSet(repo, max + 1);

    var d = Delta{
        .index = max + 1,
        .created = std.time.timestamp(),
        .updated = std.time.timestamp(),
        .repo = repo,
        .title = "",
        .message = "",
        .author = "",
        .file = file,
    };

    var thread = try Thread.new(d);
    try thread.writeOut();
    d.thread_id = thread.index;

    return d;
}

pub fn open(a: std.mem.Allocator, repo: []const u8, index: usize) !?Delta {
    const max = currMax(repo) catch 0;
    if (index > max) return null;

    var buf: [2048]u8 = undefined;
    const filename = std.fmt.bufPrint(&buf, "{s}.{x}.delta", .{ repo, index }) catch return error.InvalidTarget;
    const file = datad.openFile(filename, .{ .mode = .read_write }) catch return error.Other;
    return try Delta.readFile(a, index, file);
}

/// By assumption, a subject of len 0 will search across anything
pub const SearchRule = struct {
    subject: []const u8,
    match: []const u8,
    inverse: bool = false,
    around: bool = false,
};

pub fn SearchList(T: type) type {
    return struct {
        current: ?T = null,
        rules: []const SearchRule,

        // TODO better ABI
        iterable: std.fs.Dir.Iterator,

        const Self = @This();

        pub fn next(self: *Self, a: Allocator) anyerror!?T {
            const line = (try self.iterable.next()) orelse return null;
            if (line.kind == .file and std.mem.endsWith(u8, line.name, ".delta")) {
                if (std.mem.lastIndexOf(u8, line.name[0 .. line.name.len - 6], ".")) |i| {
                    const num = std.fmt.parseInt(
                        usize,
                        line.name[i + 1 .. line.name.len - 6],
                        16,
                    ) catch return self.next(a);
                    const file = try datad.openFile(line.name, .{});
                    self.current = Delta.readFile(a, num, file) catch {
                        file.close();
                        return self.next(a);
                    };

                    if (!self.evalRules(self.current.?)) {
                        file.close();
                        return self.next(a);
                    }

                    return self.current;
                } else {}
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

            const any = rule.subject.len == 0;

            inline for (comptime std.meta.fieldNames(T)) |name| {
                if (any or std.mem.eql(u8, rule.subject, name)) {
                    if (@TypeOf(@field(target, name)) == []const u8) {
                        const found = if (rule.around or any)
                            std.mem.count(u8, @field(target, name), rule.match) > 0
                        else
                            std.mem.eql(u8, @field(target, name), rule.match);
                        if (found) {
                            return true;
                        } else if (!any) {
                            return false;
                        }
                    }
                }
            }
            return true and !any;
        }

        pub fn raze(_: Self) void {}
    };
}

pub fn searchRepo(
    _: std.mem.Allocator,
    _: []const u8,
    _: []const SearchRule,
) SearchList(Delta) {
    unreachable;
}

pub fn search(_: std.mem.Allocator, rules: []const SearchRule) SearchList(Delta) {
    return .{
        .rules = rules,
        .iterable = datad.iterate(),
    };
}
