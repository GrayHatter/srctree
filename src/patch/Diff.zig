blob: []const u8,
header: Header,
changes: ?[]const u8 = null,
stat: Diff.Stat,
filename: ?[]const u8 = null,
blocks: ?[][]const u8 = null,

const Diff = @This();

pub const Line = union(enum) {
    hdr: []const u8,
    add: Numbered,
    del: Numbered,
    ctx: Numbered,
    empty: void,

    pub const Numbered = struct {
        number: u32,
        number_right: u32 = 0,
        text: []const u8,
    };
};

pub const Stat = struct {
    additions: usize,
    deletions: usize,
    total: isize,
};

pub const FileType = enum(u4) {
    fifo = 0o1,
    character_device = 0o2,
    directory = 0o4,
    block_device = 0o6,
    regular_file = 0o10,
    symbolic_link = 0o12,
    socket = 0o14,
    // git specific
    submodule = 0o16,

    pub fn fromAscii(chr: [2]u8) !FileType {
        return switch (try std.fmt.parseInt(u16, &chr, 8)) {
            0o4 => .directory,
            0o10 => .regular_file,
            0o16 => .submodule,
            else => |int| {
                log.err("file type parse error {}", .{int});
                return error.InvalidMode;
            },
        };
    }
};

pub const FSPerm = packed struct(u3) {
    execute: bool = false,
    write: bool = false,
    read: bool = false,

    pub fn fromAscii(chr: u8) !FSPerm {
        return switch (chr) {
            '0' => .{ .read = false, .write = false, .execute = false },
            '1' => .{ .read = false, .write = false, .execute = true },
            '2' => .{ .read = false, .write = true, .execute = false },
            '3' => .{ .read = false, .write = true, .execute = true },
            '4' => .{ .read = true, .write = false, .execute = false },
            '5' => .{ .read = true, .write = false, .execute = true },
            '6' => .{ .read = true, .write = true, .execute = false },
            '7' => .{ .read = true, .write = true, .execute = true },
            else => error.InvalidMode,
        };
    }

    pub const none: FSPerm = .{ .read = false, .write = false, .execute = false };
    pub const r: FSPerm = .{ .read = true, .write = false, .execute = false };
    pub const rw: FSPerm = .{ .read = true, .write = true, .execute = false };
    pub const rwx: FSPerm = .{ .read = true, .write = true, .execute = true };
    pub const default: FSPerm = .{ .read = true, .write = false, .execute = false };
};

test FSPerm {
    var target: FSPerm = undefined;
    const modify: *u3 = @ptrCast(&target);
    modify.* = 7;
    try std.testing.expectEqual(true, target.read);
    try std.testing.expectEqual(true, target.write);
    try std.testing.expectEqual(true, target.execute);
}

pub const Mode = packed struct(u16) {
    other: FSPerm,
    group: FSPerm,
    owner: FSPerm,
    stick: FSPerm = .{},
    file_type: FileType,

    pub fn fromStr(str: [6]u8) !Mode {
        return .{
            .other = try .fromAscii(str[5]),
            .group = try .fromAscii(str[4]),
            .owner = try .fromAscii(str[3]),
            .stick = try .fromAscii(str[2]),
            .file_type = try .fromAscii(str[0..2].*),
        };
    }

    test fromStr {
        {
            const m: Mode = try .fromStr("100444".*);
            try std.testing.expectEqual(
                Mode{ .other = .r, .group = .r, .owner = .r, .file_type = .regular_file },
                m,
            );
        }
        {
            const m: Mode = try .fromStr("100644".*);
            try std.testing.expectEqual(
                Mode{ .other = .r, .group = .r, .owner = .rw, .file_type = .regular_file },
                m,
            );
        }
        {
            const m: Mode = try .fromStr("040444".*);
            try std.testing.expectEqual(
                Mode{ .other = .r, .group = .r, .owner = .r, .file_type = .directory },
                m,
            );
        }
        {
            const m: Mode = try .fromStr("100777".*);
            try std.testing.expectEqual(
                Mode{ .other = .rwx, .group = .rwx, .owner = .rwx, .file_type = .regular_file },
                m,
            );
        }
        {
            const m: Mode = try .fromStr("160000".*);
            try std.testing.expectEqual(
                Mode{ .other = .none, .group = .none, .owner = .none, .file_type = .submodule },
                m,
            );
        }
    }
};

/// I haven't seen enough patches to know this is correct, but ideally
/// (assumably) for non merge commits a single change type should be
/// exhaustive? TODO find counter example and create test.
pub const Header = struct {
    //blob: []const u8,
    index: ?[]const u8,
    change: Change,

    const Change = union(enum) {
        none: void,
        binary: void,
        newfile: Mode,
        deletion: Mode,
        copy: SrcDst,
        rename: SrcDst,
        mode: Mode,
        similarity: []const u8,
        dissimilarity: []const u8,

        pub fn parseLine(line: []const u8) !Change {
            if (startsWith(u8, line, "similarity index")) {
                // TODO parse similarity correctly
                return .{ .similarity = line };
            } else if (startsWith(u8, line, "old mode ")) {
                return .{ .mode = try .fromStr(line["old mode ".len..][0..6].*) };
            } else if (startsWith(u8, line, "new mode ")) {
                return .{ .mode = try .fromStr(line["new mode ".len..][0..6].*) };
            } else if (startsWith(u8, line, "deleted file mode ")) {
                return .{ .deletion = try .fromStr(line["deleted file mode ".len..][0..6].*) };
            } else if (startsWith(u8, line, "new file mode ")) {
                return .{ .newfile = try .fromStr(line["new file mode ".len..][0..6].*) };
            } else if (startsWith(u8, line, "copy from ")) {
                return .{ .copy = .{
                    .src = line["copy from ".len..],
                    .dst = undefined,
                } };
            } else if (startsWith(u8, line, "copy to ")) {
                return .{ .copy = .{
                    .src = line["copy to ".len..],
                    .dst = line["copy to ".len..],
                } };
            } else if (startsWith(u8, line, "rename from ")) {
                return .{ .rename = .{
                    .src = line["rename from ".len..],
                    .dst = undefined,
                } };
            } else if (startsWith(u8, line, "rename to ")) {
                return .{ .rename = .{
                    .src = undefined,
                    .dst = line["rename to ".len..],
                } };
            } else if (startsWith(u8, line, "dissimilarity index ")) {
                return .{ .dissimilarity = line };
            } else if (startsWith(u8, line, "Binary files ")) {
                return .{ .binary = {} };
            }
            return error.UnsupportedHeader;
        }
    };

    const SrcDst = struct {
        src: []const u8,
        dst: []const u8,
    };

    fn parse(r: *Reader) !Header {
        var change: Change = .{ .none = {} };
        var index: ?[]const u8 = null;
        while (r.takeDelimiterInclusive('\n')) |current| {
            if (startsWith(u8, current, "index ")) {
                // TODO parse index correctly
                index = current;
            } else {
                change = Change.parseLine(current) catch |err| switch (err) {
                    error.UnsupportedHeader => {

                        // TODO search for '\n[^+- ]' and return change body
                        // size to caller
                        if (startsWith(u8, current, "--- ") or
                            startsWith(u8, current, "+++ ") or
                            startsWith(u8, current, "@@"))
                        {
                            r.seek -|= current.len;
                            break;
                        } else {
                            log.err("ERROR: unexpected header {s}", .{current});
                            continue;
                        }
                    },
                    else => {
                        log.err("ERROR: unsupported header {s}", .{current});
                        return err;
                    },
                };
            }
        } else |_| {}
        if (index == null and change == .none) return error.IncompleteHeader;
        return .{
            //.blob = blob,
            .index = index,
            .change = change,
        };
    }
};

/// I'm so sorry for these crimes... in my defense, I got distracted
/// while refactoring :<
pub fn parse(diff: *Diff) !?[]const u8 {
    assert(startsWith(u8, diff.blob, "diff --git a/"));

    var reader: Reader = .fixed(diff.blob);
    _ = try reader.takeDelimiterInclusive('\n');
    const header: Header = try .parse(&reader);
    diff.header = header;
    switch (header.change) {
        .deletion, .binary => return &.{},
        else => {},
    }

    if (header.index != null) {
        // TODO redact and user headers
        // Left Filename
        diff.filename = try reader.takeDelimiterInclusive('\n');
        if (!startsWith(u8, diff.filename.?, "--- ")) return error.UnableToParsePatchHeader;
        diff.filename = diff.filename.?[4..];
        diff.filename = if (eql(u8, diff.filename.?, "/dev/null\n"))
            null
        else
            diff.filename.?[2 .. diff.filename.?.len - 1];

        if (diff.filename == null) {
            diff.filename = try reader.takeDelimiterInclusive('\n');
            if (!startsWith(u8, diff.filename.?, "+++ ")) return error.UnableToParsePatchHeader;
            diff.filename = diff.filename.?[4..];
            diff.filename = if (eql(u8, diff.filename.?, "/dev/null\n"))
                null
            else
                diff.filename.?[2 .. diff.filename.?.len - 1];
        } else if (!startsWith(u8, try reader.takeDelimiterInclusive('\n'), "+++ "))
            return error.UnableToParsePatchHeader;

        // Block headers
        if (reader.peekDelimiterInclusive('\n')) |block| {
            if (!startsWith(u8, block, "@@ -") or indexOf(u8, block, " @@") == null)
                return error.BlockHeaderMissing;
        } else |_| return error.UnableToParsePatchHeader;
    }
    return reader.buffered();
}

pub fn init(blob: []const u8) !Diff {
    var d: Diff = .{
        .blob = blob,
        .header = undefined,
        .stat = .{
            .additions = count(u8, blob, "\n+"),
            .deletions = count(u8, blob, "\n-"),
            .total = @intCast(count(u8, blob, "\n+") -| count(u8, blob, "\n-")),
        },
    };
    d.changes = d.parse() catch {
        log.err("{s}", .{blob});
        unreachable;
    };
    return d;
}

/// Leaks
pub fn blocksAlloc(diff: *Diff, a: Allocator) ![]const []const u8 {
    var acount = count(u8, diff.changes.?, "\n@@");
    if (startsWith(u8, diff.changes.?, "@@")) acount += 1 else acount += 0;
    diff.blocks = try a.alloc([]const u8, acount);
    var i: usize = 0;
    var pos: usize = indexOf(u8, diff.changes.?, "@@") orelse return diff.blocks.?;
    while (indexOf(u8, diff.changes.?[pos + 1 ..], "\n@@")) |end| {
        diff.blocks.?[i] = diff.changes.?[pos..][0 .. end + 1];
        pos += end + 2;
        i += 1;
    }
    diff.blocks.?[i] = diff.changes.?[pos..];

    return diff.blocks.?;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const count = std.mem.count;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const assert = std.debug.assert;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const log = std.log.scoped(.git_patch);
