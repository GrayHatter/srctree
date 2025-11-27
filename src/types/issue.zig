index: usize,
status: Status = .open,
created: i64 = 0,
updated: i64 = 0,
repo: []const u8,
title: []const u8,
desc: []const u8,

comment_data: ?[]const u8 = null,

const Issue = @This();

pub const type_prefix = "issues";
pub const type_version: usize = 0;

const ISSUE_VERSION: usize = 0;

pub const Status = enum(u1) {
    open = 0,
    closed = 1,
};

const typeio = Types.readerWriter(Issue, .{ .index = 0, .repo = &.{}, .title = &.{}, .desc = &.{} });
const writerFn = typeio.write;
const readerFn = typeio.read;

pub fn new(repo: []const u8, title: []const u8, desc: []const u8) !Issue {
    const max: usize = try Types.nextIndex(.issue);
    const d = Issue{
        .index = max + 1,
        .state = 0,
        .repo = repo,
        .title = title,
        .desc = desc,
        .comment_data = null,
    };
    try d.commit();

    return d;
}

pub fn open(a: std.mem.Allocator, index: usize) !?Issue {
    const max = try Types.currentIndex(.issue);
    if (index > max) return error.IssueDoesNotExist;

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.issue", .{index});
    var reader = try Types.loadDataReader(.issue, a, filename);
    return readerFn(&reader.interface);
}

pub fn commit(issue: Issue) !void {
    if (issue.messages) |msgs| {
        // Make a best effort to save/protect all data
        for (msgs) |msg| msg.commit() catch continue;
    }

    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.issue", .{issue.index});
    const file = try Types.commit(.thread, filename);
    defer file.close();
    var writer = file.writer();
    try writerFn(&issue, &writer);
}

pub fn raze(self: Issue, a: std.mem.Allocator) void {
    //if (self.alloc_data) |data| {
    //    a.free(data);
    //}
    if (self.comments) |c| {
        a.free(c);
    }
    self.file.close();
}

test "reader/writer" {
    const a = std.testing.allocator;
    var writer = std.Io.Writer.Allocating.init(a);
    defer writer.deinit();

    const this: Issue = .{
        .index = 55,
        .status = .open,
        .created = 0,
        .updated = 0,
        .repo = "srctree",
        .title = "title",
        .desc = "desc",
        .comment_data = null,
    };
    try writerFn(&this, &writer.writer);

    const expected =
        \\# issues/0
        \\index: 55
        \\status: open
        \\created: 0
        \\updated: 0
        \\repo: srctree
        \\title: title
        \\desc: desc
        \\
        \\
    ;
    const expected_var = try a.dupe(u8, expected);
    defer a.free(expected_var);

    try std.testing.expectEqualStrings(expected, writer.written());

    {
        var reader: std.Io.Reader = .fixed(writer.written());
        const read_this = readerFn(&reader);
        try std.testing.expectEqualDeep(this, read_this);
    }

    {
        var reader: std.Io.Reader = .fixed(expected_var);
        const from_expected_this = readerFn(&reader);
        try std.testing.expectEqualDeep(this, from_expected_this);
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Types = @import("../types.zig");
