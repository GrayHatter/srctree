const protocol = @This();

pub const PktLine = union(enum) {
    flush,
    delimiter,
    end,
    bytes: []const u8,

    pub const Named = enum {
        flush, // 0000
        delimiter, // 0001
        end, // 0002
    };

    pub fn read(r: *std.Io.Reader) !PktLine {
        const size = std.fmt.parseInt(u16, try r.peek(4), 16) catch return error.Invalid;
        switch (size) {
            0 => {
                r.toss(4);
                return .flush;
            },
            1 => {
                r.toss(4);
                return .delimiter;
            },
            2 => {
                r.toss(4);
                return .end;
            },
            3, 4 => return error.Invalid,
            else => {},
        }
        r.toss(4);

        return .{ .bytes = try r.take(size -| 4) };
    }

    pub fn writeFlush(w: *std.Io.Writer) !void {
        try w.writeAll("0000");
        try w.flush();
    }

    pub fn write(w: *std.Io.Writer, str: []const u8) !void {
        std.debug.assert(str.len != 0);
        try w.print("{x:0>4}", .{str.len + 4});
        try w.writeAll(str);
    }

    pub fn format(pkt: PktLine, w: *std.Io.Writer) !void {
        switch (pkt) {
            .flush => try w.writeAll("0000"),
            .delimiter => try w.writeAll("0001"),
            .end => try w.writeAll("0002"),
            .bytes => |bytes| try write(w, bytes),
        }
    }
};

pub const ProcRecv = struct {
    ref: []const u8,
    old: git.Sha,
    new: git.Sha,

    pub const Options = struct {
        ref: ?[]const u8 = null,
        old: ?git.Sha = null,
        new: ?git.Sha = null,
        forced: bool = false,

        pub fn refname(name: []const u8) Options {
            return .{
                .ref = name,
                .old = null,
                .new = null,
                .forced = false,
            };
        }
    };

    // ofs-delta
    // push-cert=%s
    // session-id=%s
    // object-format=%s
    // agent=%s

    pub fn init(str: []const u8) !ProcRecv {
        if (std.mem.find(u8, str, " ")) |old_i| {
            if (old_i != 40 and old_i != 64) return error.ParseFailed;
            if (std.mem.findPos(u8, str, old_i + 1, " ")) |new_i| {
                if (new_i != 81 and new_i != 129) return error.ParseFailed;
                return .{
                    .old = .init(str[0..old_i]),
                    .new = .init(str[old_i + 1 .. new_i]),
                    .ref = str[new_i + 1 ..],
                };
            }
        }

        return error.Invalid;
    }

    pub fn ok(pr: ProcRecv, w: *std.Io.Writer) !void {
        var res_b: [512]u8 = undefined;
        const res = try std.fmt.bufPrint(&res_b, "ok {s}\n", .{pr.ref});
        try w.print("{f}", .{PktLine{ .bytes = res }});
    }

    pub fn nak(pr: ProcRecv, reason: []const u8, w: *std.Io.Writer) !void {
        var res_b: [2048]u8 = undefined;
        const res = try std.fmt.bufPrint(&res_b, "ng {s} {s}\n", .{ pr.ref, reason });
        try w.print("{f}", .{PktLine{ .bytes = res }});
    }

    pub fn fallThrough(pr: ProcRecv, w: *std.Io.Writer) !void {
        try w.print("{x:0>4}ok {s}\n", .{ 8 + pr.ref.len, pr.ref });
        try PktLine.write(w, "option fall-through\n");
    }

    pub fn writeOptions(pr: ProcRecv, w: *std.Io.Writer, options: Options) !void {
        try w.print("{x:0>4}ok {s}\n", .{ 8 + pr.ref.len, pr.ref });
        if (options.ref) |ref| try w.print("{x:0>4}option refname {s}\n", .{ 16 + ref.len + 4, ref });
        if (options.new) |new| try w.print("{x:0>4}option new-oid {f}\n", .{ 16 + new.text().slice().len + 4, new.text() });
        if (options.old) |old| try w.print("{x:0>4}option old-oid {f}\n", .{ 16 + old.text().slice().len + 4, old.text() });
        if (options.forced) try PktLine.write(w, "option forced-update");
    }

    /// Magic helper for srctree diffs
    pub fn writeDiff(pr: ProcRecv, w: *std.Io.Writer, index: usize, force: enum { forced, new }) !void {
        try w.print("{x:0>4}ok {s}\n", .{ 8 + pr.ref.len, pr.ref });
        try w.print("{x:0>4}option refname refs/diffs/{}/head\n", .{ 33 + 4 + std.fmt.count("{}", .{index}), index });
        if (force == .forced) try PktLine.write(w, "option forced-update");
    }
};

test ProcRecv {
    try std.testing.expectEqualDeep(
        ProcRecv{ .old = .zeros, .new = .init("abacde74bbdaf6f3c74e83e83186b0c91d99b06d"), .ref = "refs/heads/new" },
        ProcRecv.init("0000000000000000000000000000000000000000 abacde74bbdaf6f3c74e83e83186b0c91d99b06d refs/heads/new"),
    );
}

pub const commands = struct {
    pub const @"ls-refs" = struct {
        // https://git-scm.com/docs/protocol-v2#_ls_refs
        // caps
        // .delimiter
        // peel
        // symrefs
        // unborn
        // ref-prefix
        // flush
    };
};

pub const Caps = struct {
    @"report-status": bool,
    @"report-status-v2": bool,
    @"delete-refs": bool,
    @"side-band-64k": bool,
    quiet: bool,
    atomic: bool,
    @"ofs-delta": bool,
    @"push-options": bool,
    @"object-format": ?[]const u8,
    agent: ?[]const u8,

    multi_ack: bool,
    @"thin-pack": bool,
    @"side-band": bool,
    shallow: bool,
    @"deepen-since": bool,
    @"deepen-not": bool,
    @"deepen-relative": bool,
    @"no-progress": bool,
    @"include-tag": bool,
    multi_ack_detailed: bool,
    @"no-done": bool,

    //symref=HEAD:refs/heads/main
    //object-format=sha1
    //agent=git/2.52.0-Linux

    pub const default: Caps = receive;

    pub const upload: Caps = .{
        .@"report-status-v2" = true,
        .@"ofs-delta" = true,
        .multi_ack = true,
        .@"thin-pack" = true,
        .@"side-band" = true,
        .shallow = true,
        .@"deepen-since" = true,
        .@"deepen-not" = true,
        .@"deepen-relative" = true,
        .@"no-progress" = true,
        .@"include-tag" = true,
        .multi_ack_detailed = true,
        .@"no-done" = true,

        .@"report-status" = false,
        .@"delete-refs" = false,
        .@"side-band-64k" = false,
        .quiet = false,
        .atomic = false,
        .@"push-options" = false,

        .@"object-format" = "sha1",
        .agent = "srctree/0.0.0",
    };

    pub const receive: Caps = .{
        .@"report-status" = true,
        .@"report-status-v2" = true,
        .@"delete-refs" = true,
        .@"side-band-64k" = true,
        .quiet = true,
        .atomic = true,
        .@"ofs-delta" = true,
        .@"push-options" = true,

        .multi_ack = false,
        .@"thin-pack" = false,
        .@"side-band" = false,
        .shallow = false,
        .@"deepen-since" = false,
        .@"deepen-not" = false,
        .@"deepen-relative" = false,
        .@"no-progress" = false,
        .@"include-tag" = false,
        .multi_ack_detailed = false,
        .@"no-done" = false,

        .@"object-format" = "sha1",
        .agent = "srctree/0.0.0",
    };

    pub fn format(c: Caps, w: *std.Io.Writer) !void {
        inline for (@typeInfo(Caps).@"struct".fields) |f| {
            switch (f.type) {
                bool => if (@field(c, f.name)) try w.writeAll(f.name ++ " "),
                ?[]const u8 => if (@field(c, f.name)) |str| try w.print("{s}={s} ", .{ f.name, str }),
                else => comptime unreachable,
            }
        }
    }
};

pub fn announce(header: []const u8, c: Caps, w: *std.Io.Writer) !void {
    try w.writeAll(header);
    try w.writeAll("0000");

    var cap_buf: [512]u8 = undefined;
    var caps = std.fmt.bufPrint(&cap_buf, "{f}", .{c}) catch unreachable;
    caps.len -|= 1;

    const name = "capabilities^{}";
    const len = 4 + 40 + 1 + name.len + 1 + caps.len + 1;
    try w.print("{x:0>4}{x} {s}\x00{s}\n", .{ len, @as([20]u8, @splat(0)), name, caps });
    inline for (.{}) |_| {}
    try w.writeAll("0000");
}

pub fn announceFiltered(c: Caps, w: *std.Io.Writer) !void {
    const header = "001e# service=git-upload-pack\n";
    try announce(header, c, w);
}

pub fn announceFake(c: Caps, w: *std.Io.Writer) !void {
    const header = "001f# service=git-receive-pack\n";
    try announce(header, c, w);
}

test announce {
    var b: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&b);
    try announceFake(.default, &w);

    const expected = [_]u8{
        0x30, 0x30, 0x31, 0x66, 0x23, 0x20, 0x73, 0x65, 0x72, 0x76, 0x69, 0x63, 0x65, 0x3D, 0x67, 0x69,
        0x74, 0x2D, 0x72, 0x65, 0x63, 0x65, 0x69, 0x76, 0x65, 0x2D, 0x70, 0x61, 0x63, 0x6B, 0x0A, 0x30,
        0x30, 0x30, 0x30, 0x30, 0x30, 0x63, 0x31, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
        0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
        0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x20,
        0x63, 0x61, 0x70, 0x61, 0x62, 0x69, 0x6C, 0x69, 0x74, 0x69, 0x65, 0x73, 0x5E, 0x7B, 0x7D, 0x00,
        0x72, 0x65, 0x70, 0x6F, 0x72, 0x74, 0x2D, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x20, 0x72, 0x65,
        0x70, 0x6F, 0x72, 0x74, 0x2D, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x2D, 0x76, 0x32, 0x20, 0x64,
        0x65, 0x6C, 0x65, 0x74, 0x65, 0x2D, 0x72, 0x65, 0x66, 0x73, 0x20, 0x73, 0x69, 0x64, 0x65, 0x2D,
        0x62, 0x61, 0x6E, 0x64, 0x2D, 0x36, 0x34, 0x6B, 0x20, 0x71, 0x75, 0x69, 0x65, 0x74, 0x20, 0x61,
        0x74, 0x6F, 0x6D, 0x69, 0x63, 0x20, 0x6F, 0x66, 0x73, 0x2D, 0x64, 0x65, 0x6C, 0x74, 0x61, 0x20,
        0x70, 0x75, 0x73, 0x68, 0x2D, 0x6F, 0x70, 0x74, 0x69, 0x6F, 0x6E, 0x73, 0x20, 0x6F, 0x62, 0x6A,
        0x65, 0x63, 0x74, 0x2D, 0x66, 0x6F, 0x72, 0x6D, 0x61, 0x74, 0x3D, 0x73, 0x68, 0x61, 0x31, 0x20,
        0x61, 0x67, 0x65, 0x6E, 0x74, 0x3D, 0x73, 0x72, 0x63, 0x74, 0x72, 0x65, 0x65, 0x2F, 0x30, 0x2E,
        0x30, 0x2E, 0x30, 0x0A, 0x30, 0x30, 0x30, 0x30,
    };
    try std.testing.expectEqualSlices(u8, &expected, w.buffered());
}

pub fn emptyRepo() !void {}

test {
    std.testing.refAllDecls(@This());
    _ = &PktLine;
}

const std = @import("std");
const git = @import("../git.zig");
