index: usize,
state: State = .nos,
created: i64,
updated: i64,
number: usize = 0,
revision: usize = 0,
base_hash: []const u8 = &.{},
source_hash: []const u8 = &.{},
delta_hash: Types.DefaultHash,
author: []const u8,
source_uri: ?[]const u8,
patch: union(enum) {
    blob: []const u8,
    repo: git.Sha,
},

const Diff = @This();

pub const type_prefix = .diffs;
pub const type_version: usize = 1;

// TODO reimplement as packed struct once supported by Types.readerWriter
pub const State = enum(usize) {
    nos = 0,
    pending = 1,
    curl = 2,
    pending_curl = 3,
    diff_repo_branch = 4,
    git_push_new = 5,
    git_push_update = 6,
};

const typeio = Types.readerWriter(Diff, .{
    .index = 0,
    .created = 0,
    .updated = 0,
    .author = &.{},
    .source_uri = &.{},
    .delta_hash = undefined,
    .patch = .{ .blob = undefined },
});
const writerFn = typeio.write;
const readerFn = typeio.read;
const Index = Types.Index(type_prefix);

pub fn new(delta: *Delta, author: []const u8, patch: []const u8, a: Allocator, io: Io) !Diff {
    const idx: usize = try Index.next(io);
    const d = Diff{
        .index = idx,
        .state = .nos,
        .created = Io.Clock.now(.real, io).toSeconds(),
        .updated = Io.Clock.now(.real, io).toSeconds(),
        .delta_hash = delta.hash,
        .source_uri = null,
        .author = author,
        .patch = .{ .blob = patch },
    };

    try d.commit(io);

    var old_attach: ?usize = null;
    switch (delta.attach) {
        .nos => old_attach = null,
        .diff => old_attach = delta.attach_target,
        .remote => old_attach = null,
        .issue, .commit, .line => unreachable, // not implemented
    }

    delta.attach = .diff;
    delta.attach_target = idx;

    // TODO use hash
    const msg = if (old_attach) |old|
        try allocPrint(a, "diff patch was updated from {} to {}", .{ old, idx })
    else
        try allocPrint(a, "diff patch was created {}", .{idx});

    try delta.addMessage(try .new(.diff_update, idx, author, msg, io), a, io);
    return d;
}

pub fn open(index: usize, a: Allocator, io: Io) !?Diff {
    const max = try Index.current(io);
    if (index > max) return null;

    var buf: [512]u8 = undefined;
    const filename = try print(&buf, "{x}.diff", .{index});
    var reader = try Types.loadDataReader(.diffs, filename, a, io);
    var d: Diff = readerFn(&reader);

    // TODO reader.buffered();
    if (find(u8, reader.buffer, "\n\n")) |start| {
        d.patch.blob = reader.buffer[start..];
    } else d.patch.blob = &.{};

    return d;
}

pub fn commit(d: Diff, io: Io) !void {
    var buf: [512]u8 = undefined;
    const filename = try print(&buf, "{x}.diff", .{d.index});
    const file = try Types.commit(.diffs, filename, io);
    defer file.close(io);
    var w_b: [2048]u8 = undefined;
    var fd_writer = file.writer(io, &w_b);
    try writerFn(&d, &fd_writer.interface);
    try fd_writer.interface.writeAll(std.mem.trimStart(u8, d.patch.blob, "\n"));
    try fd_writer.interface.flush();
}

pub const Revision = enum(usize) {
    first = 0,
    one = maxInt(usize) - 3,
    prev = maxInt(usize) - 2,
    current = maxInt(usize) - 1,
    last = maxInt(usize),
    _,

    pub fn rev(u: usize) Revision {
        return @enumFromInt(u);
    }

    pub fn fromStr(str: []const u8) !Revision {
        const u: usize = std.fmt.parseInt(usize, str, 0) catch return error.NotANumber;
        return .rev(u);
    }
};

pub fn patchFromGitRev(
    d: *const Diff,
    base_rev: ?[]const u8,
    diff_rev: Revision,
    agent: *const git.Agent,
    io: Io,
) error{ServerFault}!Patch {
    const base = base_rev orelse if (d.base_hash.len > 0) d.base_hash else "HEAD";
    var b: [512]u8 = undefined;
    const target: []const u8 = switch (diff_rev) {
        .first => print(&b, "{s}..refs/diffs/{d}/rev-0", .{ base, d.number }) catch unreachable,
        .prev => print(&b, "{s}..refs/diffs/{d}/rev-{d}", .{ base, d.number, d.revision -| 1 }) catch unreachable,
        .current => print(&b, "{s}..refs/diffs/{d}/head", .{ base, d.number }) catch unreachable,
        // TODO find actual last
        .last => print(&b, "{s}..refs/diffs/{d}/head", .{ base, d.number }) catch unreachable,
        // experimental
        .one => print(&b, "refs/diffs/{d}/head^..refs/diffs/{d}/head", .{ d.number, d.number }) catch unreachable,
        else => |num| print(&b, "{s}..refs/diffs/{d}/rev-{d}", .{ base, d.number, num }) catch unreachable,
    };
    log.info("revision {} {s}", .{ diff_rev, target });

    // TODO verify patch and rev exists
    const blob = agent.formatPatchRange(target, io) catch return error.ServerFault;
    return .init(blob);
}

pub fn getPatch(d: *const Diff, agent: *const git.Agent, io: Io) !Patch {
    return d.getPatchRev(.current, agent, io);
}

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.types_diff);
const print = std.fmt.bufPrint;
const allocPrint = std.fmt.allocPrint;
const find = std.mem.find;
const maxInt = std.math.maxInt;

const git = @import("../git.zig");
const Patch = @import("../Patch.zig");
const Types = @import("../types.zig");
const Delta = @import("delta.zig");
