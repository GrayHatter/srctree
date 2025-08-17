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
    const file = try Types.loadData(.issue, a, filename);
    return readerFn(file);
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

//pub fn getComments(self: *Issue, a: Allocator) ![]Comment {
//    if (self.comments) |_| return self.comments.?;
//
//    if (self.comment_data) |cd| {
//        self.comments = try Comment.loadFromData(a, cd);
//    }
//    return &[0]Comment{};
//}
//
//pub fn addComment(self: *Issue, a: Allocator, c: Comment) !void {
//    const target = (self.comments orelse &[0]Comment{}).len;
//    if (self.comments) |*comments| {
//        if (a.resize(comments.*, target + 1)) {
//            comments.*.len = target + 1;
//        } else {
//            self.comments = try a.realloc(comments.*, target + 1);
//        }
//    } else {
//        self.comments = try a.alloc(Comment, target + 1);
//    }
//    self.comments.?[target] = c;
//    try self.writeOut();
//}

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
    var list = std.ArrayList(u8).init(a);
    defer list.clearAndFree();
    var writer = list.writer();

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
    try writerFn(&this, &writer);

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

    try std.testing.expectEqualStrings(expected, list.items);

    {
        const read_this = readerFn(list.items);
        try std.testing.expectEqualDeep(this, read_this);
    }

    {
        const from_expected_this = readerFn(expected);
        try std.testing.expectEqualDeep(this, from_expected_this);
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Types = @import("../types.zig");
