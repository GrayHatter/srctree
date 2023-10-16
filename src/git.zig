const std = @import("std");

const Allocator = std.mem.Allocator;
const zlib = std.compress.zlib;

const DateTime = @import("datetime.zig");

const Types = enum {
    commit,
    blob,
    tree,
};

const SHA = []const u8; // SUPERBAD, I'm sorry!

const Actor = struct {
    name: []const u8,
    email: []const u8,
    time: DateTime,
    tz_offset: i8,

    pub fn make(data: []const u8) !Actor {
        var itr = std.mem.splitBackwards(u8, data, " ");
        var tz = itr.next() orelse return error.ActorParseError;
        var time = try DateTime.fromEpochStr(itr.next() orelse return error.ActorParseError);
        var email = itr.next() orelse return error.ActorParseError;
        var name = itr.rest();
        _ = tz;
        return .{
            .name = name,
            .email = email,
            .time = time,
            .tz_offset = 0,
        };
    }

    pub fn format(self: Actor, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        try out.print("Actor{{ name {s}, email {s} time {} }}", .{ self.name, self.email, self.time });
    }
};

const Commit = struct {
    blob: []const u8,
    sha: SHA,
    parent: SHA,
    author: Actor,
    committer: Actor,
    message: []const u8,

    ptr_parent: ?*Commit = null, // TOOO multiple parents

    fn header(self: *Commit, data: []const u8) !void {
        if (std.mem.indexOf(u8, data, " ")) |brk| {
            const name = data[0..brk];
            const payload = data[brk..];
            if (std.mem.eql(u8, name, "commit")) {
                self.sha = payload;
            } else if (std.mem.eql(u8, name, "parent")) {
                self.parent = payload;
            } else if (std.mem.eql(u8, name, "author")) {
                self.author = try Actor.make(payload);
            } else if (std.mem.eql(u8, name, "committer")) {
                self.committer = try Actor.make(payload);
            } else return error.UnknownHeader;
        } else return error.MalformedHeader;
    }

    pub fn make(data: []const u8) !Commit {
        var lines = std.mem.split(u8, data, "\n");
        var self: Commit = undefined;
        self.blob = data;
        while (lines.next()) |line| {
            if (line.len == 0) break;
            try self.header(line);
        }
        self.message = lines.rest();
        return self;
    }

    pub fn readFile(a: Allocator, file: std.fs.File) !Commit {
        var d = try zlib.decompressStream(a, file.reader());
        defer d.deinit();
        var buf = try a.alloc(u8, 1 << 16);
        const count = try d.read(buf);
        if (count == 1 << 16) return error.FileDataTooLarge;
        var self = try make(buf[0..count]);
        self.blob = buf;
        return self;
    }

    pub fn format(self: Commit, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        try out.print(
            \\Commit{{
            \\commit {s}
            \\parent {s}
            \\author {}
            \\commiter {}
            \\
            \\{s}
            \\}}
        , .{ self.sha, self.parent, self.author, self.committer, self.message });
    }
};

test "read" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./.git/objects/37/0303630b3fc631a0cb3942860fb6f77446e9c1", .{});
    var b: [1 << 16]u8 = undefined;

    var d = try zlib.decompressStream(a, file.reader());
    defer d.deinit();
    var count = try d.read(&b);
    //std.debug.print("{s}\n", .{b[0..count]});
    const commit = try Commit.make(b[0..count]);
    //std.debug.print("{}\n", .{commit});
    try std.testing.expectEqualStrings("fcb6817b0efc397f1525ff7ee375e08703ed17a9", commit.sha[10..]);
}

test "file" {
    var a = std.testing.allocator;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./.git/objects/37/0303630b3fc631a0cb3942860fb6f77446e9c1", .{});
    const commit = try Commit.readFile(a, file);
    defer a.free(commit.blob);
    //std.debug.print("{}\n", .{commit});
    try std.testing.expectEqualStrings("fcb6817b0efc397f1525ff7ee375e08703ed17a9", commit.sha[10..]);
}
