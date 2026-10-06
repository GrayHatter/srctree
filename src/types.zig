const types = @This();

pub const common = @import("types/common.zig");
pub const search = @import("types/search.zig");

pub const Artifact = @import("types/Artifact.zig");
pub const CI = @import("types/CI.zig");
pub const Delta = @import("types/Delta.zig");
pub const Diff = @import("types/Diff.zig");
pub const Gist = @import("types/Gist.zig");
pub const Issue = @import("types/Issue.zig");
pub const Message = @import("types/Message.zig");
pub const Network = @import("types/Network.zig");
pub const Tags = @import("types/Tags.zig");
pub const Thread = @import("types/Thread.zig");
pub const User = @import("types/User.zig");
pub const Viewers = @import("types/Viewers.zig");

pub const DefaultHash = [DefaultHasher.digest_length]u8;
pub const DefaultHasher = std.crypto.hash.sha2.Sha256;
pub const Sha1Hex = [40]u8;
pub const Sha1Bin = [20]u8;
pub const Sha256Hex = [64]u8;
pub const Sha256Bin = [32]u8;
pub const Timestamp = i64;

pub const Storage = Io.Dir;

pub fn VarString(comptime size: usize) type {
    return struct {
        buffer: [size]u8 = undefined,
        len: usize = 0,

        pub const is_var_string = true;
        pub const Self = @This();

        pub fn init(str: []const u8) Self {
            const len = @min(size, str.len);
            var self: Self = .{
                .len = len,
            };
            @memcpy(self.buffer[0..len], str[0..len]);
            return self;
        }

        pub fn slice(str: *const Self) []const u8 {
            return str.buffer[0..str.len];
        }

        pub fn writeableSlice(str: *Self) []u8 {
            return str.buffer[str.len..];
        }
    };
}

const custom_types: struct {
    types: []const type,
    pub fn contains(comptime es: @This(), t: type) bool {
        inline for (es.types) |enable| if (enable == t) return true;
        return false;
    }
} = .{ .types = &.{
    common.State,
} };

var storage_dir: Storage = undefined;

pub fn currentPathAlloc(a: Allocator, io: Io) ![]u8 {
    return storage_dir.realPathFileAlloc(io, ".", a) catch return error.OutOfMemory;
}

pub fn init(dir: Storage, io: Io) !void {
    storage_dir = dir;
    inline for (.{
        Artifact, CI,     Delta, Diff,    Gist, Issue, Message,
        Network,  Thread, User,  Viewers,
    }) |inc| {
        if (@hasDecl(inc, "initType") and @hasDecl(inc, "TYPE_PREFIX")) {
            try inc.initType(try dir.createDirPathOpen(io, inc.TYPE_PREFIX, .{
                .open_options = .{ .iterate = true },
            }));
        }
    }
}

pub fn raze(io: Io) void {
    storage_dir.close(io);
}

pub fn iterableDir(comptime type_name: @EnumLiteral(), io: Io) !Io.Dir {
    return try storage_dir.createDirPathOpen(io, @tagName(type_name), .{
        .open_options = .{ .iterate = true },
    });
}

fn openFile(comptime type_name: @EnumLiteral(), filename: []const u8, io: Io) !Io.File {
    var type_dir = try storage_dir.createDirPathOpen(io, @tagName(type_name), .{});
    defer type_dir.close(io);
    return try type_dir.openFile(io, filename, .{});
}

fn createFile(comptime type_name: @EnumLiteral(), filename: []const u8, io: Io) !Io.File {
    var type_dir = try storage_dir.createDirPathOpen(io, @tagName(type_name), .{});
    defer type_dir.close(io);
    return try type_dir.createFile(io, filename, .{});
}

pub fn loadDataAlloc(comptime type_name: @EnumLiteral(), name: []const u8, a: Allocator, io: Io) ![]u8 {
    const file = try openFile(type_name, name, io);
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try a.alloc(u8, stat.size);
    errdefer a.free(buf);
    var reader = file.reader(io, buf);
    try reader.interface.fill(stat.size);
    return buf;
}

pub fn loadDataReader(comptime type_name: @EnumLiteral(), name: []const u8, a: Allocator, io: Io) !Io.Reader {
    const file = try openFile(type_name, name, io);
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try a.alloc(u8, stat.size);
    errdefer a.free(buf);
    var reader = file.reader(io, buf);
    try reader.interface.fill(stat.size);
    return .fixed(reader.interface.buffer);
}

pub fn loadDataHashId(comptime type_name: @EnumLiteral(), hash: DefaultHash, a: Allocator, io: Io) !Io.Reader {
    var buf: [@sizeOf(DefaultHash) * 2 + 1 + @tagName(type_name).len]u8 = undefined;
    const filename = print(&buf, "{x}." ++ @tagName(type_name), .{&hash}) catch unreachable;
    return loadDataReader(type_name, filename, a, io);
}

pub fn commit(comptime type_name: @EnumLiteral(), name: []const u8, io: Io) !Io.File {
    var type_dir = try storage_dir.createDirPathOpen(io, @tagName(type_name), .{});
    defer type_dir.close(io);
    return try type_dir.createFile(io, name, .{});
}

pub fn commitHashId(comptime type_name: @EnumLiteral(), hash: DefaultHash, io: Io) !Io.File {
    var buf: [@sizeOf(DefaultHash) * 2 + 1 + @tagName(type_name).len]u8 = undefined;
    const filename = print(&buf, "{x}." ++ @tagName(type_name), .{&hash}) catch unreachable;
    var type_dir = try storage_dir.createDirPathOpen(io, @tagName(type_name), .{});
    defer type_dir.close(io);
    return try type_dir.createFile(io, filename, .{});
}

pub fn Index(type_name: @EnumLiteral()) type {
    return struct {
        var mutex: std.Io.Mutex = .init;
        pub const name = "_" ++ @tagName(type_name) ++ ".index";
        pub const pathfmt = "repo_scoped/{s}/" ++ name;

        pub fn current(io: Io) !usize {
            try mutex.lock(io);
            defer mutex.unlock(io);
            var index_file = storage_dir.openFile(io, name, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    var new_file = try storage_dir.createFile(io, name, .{});
                    defer new_file.close(io);
                    try increment(new_file, 0, io);
                    return 0;
                },
                else => return err,
            };
            defer index_file.close(io);
            var r_b: [10]u8 = undefined;
            var fd_reader = index_file.reader(io, &r_b);
            const reader = &fd_reader.interface;
            const idx = reader.takeInt(usize, .big) catch 0;
            return idx;
        }

        fn increment(fd: Io.File, idx: usize, io: Io) !void {
            var writer = fd.writer(io, &.{});
            try writer.interface.writeInt(usize, idx, .big);
            try writer.interface.flush();
        }

        pub fn next(io: Io) !usize {
            try mutex.lock(io);
            defer mutex.unlock(io);
            var index_file = try storage_dir.createFile(io, name, .{ .read = true, .truncate = false });
            defer index_file.close(io);
            var r_b: [10]u8 = undefined;
            var reader = index_file.reader(io, &r_b);
            var idx = reader.interface.takeInt(usize, .big) catch 0;
            idx += 1;
            try increment(index_file, idx, io);
            return idx;
        }

        pub fn openFile(idx: usize, io: Io) !Io.File {
            var buf: [4096]u8 = undefined;
            const filename = try print(&buf, "{x}." ++ @tagName(type_name), .{idx});
            return try types.openFile(type_name, filename, io);
        }

        pub fn createFile(idx: usize, io: Io) !Io.File {
            var buf: [4096]u8 = undefined;
            const filename = try print(&buf, "{x}." ++ @tagName(type_name), .{idx});
            return try types.createFile(type_name, filename, io);
        }

        pub fn readerByIndex(idx: usize, a: Allocator, io: Io) !Io.Reader {
            const file = try @This().fileByIndex(idx, io);
            defer file.close(io);
            const stat = try file.stat(io);
            const buf = try a.alloc(u8, stat.size);
            errdefer a.free(buf);
            var reader = file.reader(io, buf);
            try reader.interface.fill(stat.size);
            return .fixed(reader.interface.buffer);
        }

        pub const scoped = struct {
            var pbuf: [2048]u8 = undefined;

            pub fn current(scope: []const u8, io: Io) !usize {
                try mutex.lock(io);
                defer mutex.unlock(io);
                const ename = try print(&pbuf, "_{s}.{s}", .{ scope, name[1..] });
                var index_file = storage_dir.openFile(io, ename, .{}) catch |err| switch (err) {
                    error.FileNotFound => {
                        var new_file = try storage_dir.createFile(io, ename, .{});
                        defer new_file.close(io);
                        try increment(new_file, 0, io);
                        return 0;
                    },
                    else => return err,
                };
                defer index_file.close(io);
                var r_b: [10]u8 = undefined;
                var fd_reader = index_file.reader(io, &r_b);
                var reader = &fd_reader.interface;
                const idx = reader.takeInt(usize, .big) catch 0;
                return idx;
            }

            pub fn next(scope: []const u8, io: Io) !usize {
                try mutex.lock(io);
                defer mutex.unlock(io);
                const ename = try print(&pbuf, "_{s}.{s}", .{ scope, name[1..] });
                var index_file = try storage_dir.createFile(io, ename, .{ .read = true, .truncate = false });
                defer index_file.close(io);
                var r_b: [10]u8 = undefined;
                var reader = index_file.reader(io, &r_b);
                var idx = reader.interface.takeInt(usize, .big) catch 0;
                idx += 1;
                try increment(index_file, idx, io);
                return idx;
            }

            pub fn fileByIndex(repo: []const u8, idx: usize, io: Io) !Io.File {
                var buf: [4096]u8 = undefined;
                const filename = try print(&buf, "{s}.{x}." ++ @tagName(type_name), .{ repo, idx });
                return try types.openFile(type_name, filename, io);
            }

            pub fn readerByIndex(repo: []const u8, idx: usize, a: Allocator, io: Io) !Io.Reader {
                const file = try @This().fileByIndex(repo, idx, io);
                defer file.close(io);
                const stat = try file.stat(io);
                const buf = try a.alloc(u8, stat.size);
                errdefer a.free(buf);
                var reader = file.reader(io, buf);
                try reader.interface.fill(stat.size);
                return .fixed(reader.interface.buffer);
            }
        };
    };
}

pub fn split(line: []u8) ?struct { []u8, [:'\n']u8 } {
    const idx = indexOf(u8, line, ": ") orelse return null;
    return .{ line[0..idx], line[idx + 2 .. line.len - 1 :'\n'] };
}

pub fn readerWriter(BaseType: type, default: BaseType) type {
    return struct {
        pub fn read(r: *Io.Reader) BaseType {
            return readStruct(BaseType, default, "", r);
        }

        fn readStruct(T: type, sub_default: T, comptime prefix: []const u8, r: *Io.Reader) T {
            var output: T = sub_default;
            while (r.takeDelimiterInclusive('\n')) |line| {
                if (line.len == 1 and line[0] == '\n') return output;
                const name: []u8, const value: [:'\n']u8 = split(line) orelse continue;
                const S = @typeInfo(T).@"struct";
                inline for (S.field_names, S.field_types) |fname, ftype| {
                    const dst = &@field(output, fname);
                    const prefixed_name = if (prefix.len > 0) prefix ++ "." ++ fname else fname;
                    if (eql(u8, name, prefixed_name)) switch (ftype) {
                        DefaultHash => if (value.len == 64) {
                            var hex: []const u8 = value;
                            for (0..32) |i| {
                                dst.*[i] = parseInt(u8, hex[0..2], 16) catch 0;
                                hex = hex[2..];
                            }
                        } else log.warn("bad value length when reading " ++ fname, .{}),
                        Sha1Hex => if (value.len == 40) @memcpy(dst.*[0..40], value[0..40]),
                        Sha1Bin => if (value.len == 40) {
                            var hex: []const u8 = value;
                            for (0..20) |i| {
                                dst.*[i] = parseInt(u8, hex[0..2], 16) catch 0;
                                hex = hex[2..];
                            }
                        } else log.warn("bad value length when reading " ++ fname, .{}),
                        []u8, []const u8, ?[]const u8 => {
                            for (value) |*chr| {
                                if (chr.* == 0x1a) chr.* = '\n';
                            }
                            dst.* = value;
                        },
                        usize => dst.* = parseInt(usize, value, 10) catch dst.*,
                        i64 => dst.* = parseInt(i64, value, 10) catch dst.*,
                        i32 => dst.* = parseInt(i32, value, 10) catch dst.*,
                        bool => dst.* = eql(u8, value, "true"),
                        VarString(128) => dst.* = VarString(128).init(value),
                        VarString(256) => dst.* = VarString(256).init(value),
                        Viewers => dst.* = Viewers.fromLine(value) catch .empty,
                        Delta.Attach => dst.* = stringToEnum(ftype, value) orelse dst.*,
                        User.Type => dst.* = stringToEnum(ftype, value) orelse dst.*,
                        CI.Step => dst.* = stringToEnum(ftype, value) orelse dst.*,
                        CI.Result => dst.* = stringToEnum(ftype, value) orelse dst.*,
                        Issue.Status => dst.* = stringToEnum(ftype, value) orelse dst.*,

                        std.debug.SafetyLock => unreachable,
                        std.debug.SafetyLock.State => unreachable,

                        ?Io.File,
                        ?Io.Writer,
                        []const Gist.File, // Managed internally by Gist
                        ArrayList(Message), // Managed internally by Threads
                        ArrayList(Viewers.View), // Managed internally by Viewers
                        ArrayList(CI.Step), // Managed internally by CI
                        ?*Thread,
                        => if (comptime type_debugging) log.info(
                            "building {s} reader skipped `{s}: {s}` (intentionally skipped)",
                            .{ @typeName(T), fname, @typeName(ftype) },
                        ),
                        else => switch (@typeInfo(ftype)) {
                            .@"enum" => |enumT| {
                                if (enumT.mode == .nonexhaustive)
                                    @compileError(
                                        prefix ++
                                            prefixed_name ++
                                            @typeName(ftype) ++
                                            @typeName(BaseType) ++
                                            @typeName(T) ++
                                            " non-exaustive enums are not supported",
                                    );
                                if (comptime type_debugging) log.warn("unexpected type {s} on {s} (magic fill)", .{
                                    @typeName(ftype), @typeName(T),
                                });
                                if (std.meta.stringToEnum(ftype, value)) |enumV| {
                                    dst.* = enumV;
                                }
                            },
                            else => if (comptime type_debugging) log.err("skipped type {s} on {s}", .{
                                @typeName(ftype), @typeName(T),
                            }),
                        },
                    } else if (startsWith(u8, name, fname) and
                        name.len > fname.len and
                        name[fname.len] == '.') switch (@typeInfo(ftype)) {
                        .@"struct" => if (custom_types.contains(ftype)) {
                            const save = r.seek;
                            r.seek -|= line.len;
                            dst.* =
                                readStruct(ftype, dst.*, fname, r);
                            r.seek = save;
                        } else if (comptime type_debugging) log.err(
                            "building {s} reader skipped `{s}: {s}` (not enabled)",
                            .{ @typeName(T), fname, @typeName(ftype) },
                        ),
                        else => log.err(
                            "building {s} reader skipped `{s}: {s}` (not enabled)",
                            .{ @typeName(T), fname, @typeName(ftype) },
                        ),
                    };
                }
            } else |err| switch (err) {
                error.EndOfStream => {},
                else => log.err("incomplete read on {s} {}", .{ @typeName(T), err }),
            }

            return output;
        }

        pub fn write(t: *const BaseType, w: *Writer) error{WriteFailed}!void {
            if (@hasDecl(BaseType, "type_prefix") and @hasDecl(BaseType, "type_version")) {
                try w.print("# {s}/{d}\n", .{ @tagName(BaseType.type_prefix), BaseType.type_version });
            }

            try writeStruct(BaseType, t, "", w);
            try w.writeAll("\n");
            try w.flush();
        }

        fn writeStruct(T: type, t: *const T, comptime name: []const u8, w: *Writer) error{WriteFailed}!void {
            const S = @typeInfo(T).@"struct";
            all: inline for (S.field_names, S.field_types) |fname, ftype| {
                if (comptime @hasDecl(BaseType, "type_skip_fields")) {
                    inline for (BaseType.type_skip_fields) |skip| {
                        if (comptime eql(u8, skip, fname)) continue :all;
                    }
                }
                if (name.len > 0) try w.writeAll(name ++ ".");

                const src = &@field(t, fname);
                switch (ftype) {
                    []u8,
                    []const u8,
                    ?[]const u8,
                    VarString(128),
                    VarString(256),
                    => |kind| {
                        const value: ?[]const u8 = switch (kind) {
                            []u8, []const u8, ?[]const u8 => src.*,
                            VarString(128), VarString(256) => src.*.slice(),
                            else => comptime unreachable,
                        };
                        if (value) |v| {
                            if (v.len > 0) {
                                try w.print("{s}: ", .{fname});
                                var itr = splitScalar(u8, v, '\n');
                                while (itr.next()) |line| {
                                    try w.writeAll(line);
                                    if (itr.peek()) |_| try w.writeAll("\x1a");
                                }
                                try w.writeAll("\n");
                            }
                        }
                    },

                    DefaultHash => try w.print("{s}: {x}\n", .{ fname, src.* }),
                    Sha1Bin => try w.print("{s}: {x}\n", .{ fname, src.* }),
                    Sha1Hex => try w.print("{s}: {s}\n", .{ fname, src.* }),
                    usize,
                    isize,
                    i64,
                    i32,
                    => try w.print("{s}: {d}\n", .{ fname, src.* }),
                    bool => try w.print(
                        "{s}: {s}\n",
                        .{ fname, if (src.*) "true" else "false" },
                    ),
                    Viewers => try w.print("{s}: {f}\n", .{ fname, src.* }),
                    Delta.Attach => try w.print("{s}: {s}\n", .{ fname, @tagName(src.*) }),
                    User.Type => try w.print("{s}: {s}\n", .{ fname, @tagName(src.*) }),
                    CI.Step => try w.print("{s}: {s}\n", .{ fname, @tagName(src.*) }),
                    CI.Result => try w.print("{s}: {s}\n", .{ fname, @tagName(src.*) }),
                    Issue.Status => try w.print("{s}: {s}\n", .{ fname, @tagName(src.*) }),

                    ?Io.File,
                    ?Io.Writer,
                    []const Gist.File, // Managed internally by Gist
                    ArrayList(Message), // Managed internally by Threads
                    ArrayList(Viewers.View), // Managed internally by Viewers
                    ArrayList(CI.Step), // Managed internally by CI
                    ?*Thread,
                    => if (comptime type_debugging) log.warn(
                        "building {s} writer skipped `{s}: {s}` (intentionally skipped)",
                        .{ @typeName(T), fname, @typeName(ftype) },
                    ),
                    else => switch (@typeInfo(ftype)) {
                        .@"enum" => |enumT| {
                            if (enumT.mode == .nonexhaustive) @compileError("non-exaustive enums are not supported");
                            try w.print("{s}: {s}\n", .{ fname, @tagName(src.*) });
                            if (comptime type_debugging) log.info(
                                "building {s} writer skipped `{s}: {s}` (magic fill)",
                                .{ @typeName(T), fname, @typeName(ftype) },
                            );
                        },
                        .@"struct" => {
                            if (custom_types.contains(ftype)) {
                                const prefix = if (name.len > 0) name ++ "." ++ fname else fname;
                                try writeStruct(ftype, src, prefix, w);
                            } else if (comptime type_debugging) log.err(
                                "building {s} writer skipped `{s}: {s}` (not enabled)",
                                .{ @typeName(T), fname, @typeName(ftype) },
                            );
                        },
                        else => if (comptime type_debugging) log.err(
                            "building {s} writer skipped `{s}: {s}` (not enabled)",
                            .{ @typeName(T), fname, @typeName(ftype) },
                        ),
                    },
                }
            }
        }
    };
}

pub inline fn shaToHash(sha: git.Sha) DefaultHash {
    var hash: DefaultHash = @splat(0);
    if (git.Sha.Hash.max_len > @sizeOf(DefaultHash)) @compileError("git Sha is larger than types.DefaultHash");
    switch (sha.hash) {
        .sha1 => |sha1| hash[0..20].* = sha1,
        .sha256 => |sha256| hash = sha256,
        .partial => unreachable,
    }
    return hash;
}

pub const testing = struct {
    pub fn maskTime(thing: anytype, io: Io) void {
        // LOL, you thought
        const T = @typeInfo(@TypeOf(thing)).pointer.child;
        comptime std.debug.assert(@hasField(T, "created"));
        comptime std.debug.assert(@hasField(T, "updated"));
        const mask: i64 = ~@as(i64, 0x7ffffff);
        const now = Io.Clock.real.now(io).toSeconds();
        thing.*.created = now & mask;
        thing.*.updated = now & mask;
    }
};

test {
    _ = &common;
    _ = &search;
    _ = &Artifact;
    _ = &CI;
    _ = &Delta;
    _ = &Diff;
    _ = &Gist;
    _ = &Issue;
    _ = &Message;
    _ = &Network;
    _ = &Tags;
    _ = &Thread;
    _ = &User;
    _ = &Viewers;
}

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Reader = Io.File.Reader;
const fs = std.fs;
const log = std.log.scoped(.srctree_type);
const parseInt = std.fmt.parseInt;
const indexOf = std.mem.indexOf;
const splitScalar = std.mem.splitScalar;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const print = std.fmt.bufPrint;
const stringToEnum = std.meta.stringToEnum;
const git = @import("git.zig");

const type_debugging = false;
