/// This probably should pipe/flow/depend on `git notes` but here we are...
const std = @import("std");

const Allocator = std.mem.Allocator;

const Comments = @import("comments.zig");
const Comment = Comments.Comment;

pub const CommitMap = struct {
    version: u8 = 0,
    hash: []const u8,
    comments: []Comment,

    file: std.fs.File,

    pub fn writeOut(self: CommitMap) !void {
        try self.file.seekTo(0);
        var writer = self.file.writer();
        if (self.comments) |cmts| {
            for (cmts) |*c| {
                try writer.writeAll(c.toHash());
            }
        }
        //try writer.writeAll("\x00");
        try self.file.setEndPos(self.file.getPos() catch unreachable);
    }

    pub fn readFile(a: std.mem.Allocator, hash: []const u8, file: std.fs.File) !CommitMap {
        const end = try file.getEndPos();
        var data = try a.alloc(u8, end);
        errdefer a.free(data);
        try file.seekTo(0);
        const rlen = try file.readAll(data);
        const ver = if (rlen > 0) data[0] else 0;
        const cdata = if (rlen > 0) data[1..] else &[0]u8{};
        var list = std.ArrayList(Comment).init(a);
        const count = cdata.len / 32;
        for (0..count) |i| {
            try list.append(try Comments.open(a, cdata[i * 32 .. (i + 1) * 32]));
        }

        std.debug.assert(ver == 0);

        return CommitMap{
            .version = ver,
            .hash = try a.dupe(u8, hash),
            .comments = try list.toOwnedSlice(),
            .file = file,
        };
    }
};

var datad: std.fs.Dir = undefined;

pub fn init(dir: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}/cmmtmap", .{dir});
    datad = try std.fs.cwd().openDir(filename, .{});
}

pub fn raze() void {
    datad.close();
}

pub fn open(a: Allocator, hash: []const u8) !CommitMap {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{x}.cmap", .{std.fmt.fmtSliceHexLower(hash)});
    var file = try datad.createFile(filename, .{});
    return try CommitMap.readFile(a, hash, file);
}
