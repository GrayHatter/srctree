const types = @This();

pub const Artifact = @import("types/Artifact.zig");
pub const CI = @import("types/CI.zig");
pub const Delta = @import("types/Delta.zig");
pub const Diff = @import("types/Diff.zig");
pub const Gist = @import("types/Gist.zig");
pub const Message = @import("types/Message.zig");
pub const Network = @import("types/Network.zig");
pub const RepoMeta = @import("types/RepoMeta.zig");
pub const Tags = @import("types/Tags.zig");
pub const Thread = @import("types/Thread.zig");
pub const User = @import("types/User.zig");
pub const Viewers = @import("types/Viewers.zig");

pub const State = common.State;

pub const DefaultHash = [DefaultHasher.digest_length]u8;
pub const DefaultHasher = std.crypto.hash.sha2.Sha256;
pub const Sha1Hex = [40]u8;
pub const Sha1Bin = [20]u8;
pub const Sha256Hex = [64]u8;
pub const Sha256Bin = [32]u8;

// Reexposed in case it needs to become an "internal type"
pub const GitSha = git.Sha;

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

pub fn init(dir: Storage, _: Io) !void {
    storage_dir = dir;
}

pub fn raze(io: Io) void {
    storage_dir.close(io);
}

pub fn split(line: []u8) ?struct { []u8, [:'\n']u8 } {
    const idx = indexOf(u8, line, ": ") orelse return null;
    return .{ line[0..idx], line[idx + 2 .. line.len - 1 :'\n'] };
}

pub const CommitError = error{
    Canceled,
    FSError,
    NoSpaceLeft,
    WriteFailed,
};

pub const ReadError = error{
    EndOfStream,
    FSError,
    OutOfMemory,
    ReadFailed,
};

pub fn TypedIo(BaseType: type) type {
    return struct {
        pub const TypeIo = @This();

        pub const type_prefix: @EnumLiteral() = if (@hasDecl(BaseType, "type_prefix"))
            BaseType.type_prefix
        else
            @compileError("Type needs a type_prefix enum literal");

        const fmtstr = "{f}." ++ @tagName(type_prefix);

        pub const Index = struct {
            pub const tidx_name = "_" ++ @tagName(type_prefix) ++ ".index";
            var mutex: std.Io.Mutex = .init;

            fn writeIndex(fd: Io.File, idx: usize, io: Io) CommitError!void {
                var writer = fd.writer(io, &.{});
                try writer.interface.writeInt(usize, idx, .big);
                try writer.interface.flush();
            }

            fn takeInt(_: *Io.Reader) usize {}

            pub fn new(io: Io) CommitError!usize {
                log.info(@typeName(BaseType) ++ ".Index.next not found, creating", .{});
                var new_file = createIndexFile(io) catch @panic("CreateIndexPanic");
                defer new_file.close(io);
                try writeIndex(new_file, 1, io);
                return 1;
            }

            pub fn current(io: Io) CommitError!usize {
                try mutex.lock(io);
                defer mutex.unlock(io);

                var index_file = openIndexFile(io) catch |err| switch (err) {
                    error.FileNotFound => return new(io),
                    else => {
                        log.err(@typeName(BaseType) ++ ".Index.scoped.next not found {}", .{err});
                        return error.FSError;
                    },
                };
                defer index_file.close(io);
                var r_b: [10]u8 = undefined;
                var fd_reader = index_file.reader(io, &r_b);
                const reader = &fd_reader.interface;
                const idx = reader.takeInt(usize, .big) catch 0;
                return idx;
            }

            pub fn next(io: Io) CommitError!usize {
                try mutex.lock(io);
                defer mutex.unlock(io);

                var index_file = openIndexFile(io) catch |err| idxf: {
                    log.info(@typeName(BaseType) ++ ".Index.next failed {}", .{err});
                    break :idxf createIndexFile(io) catch return error.FSError;
                };
                defer index_file.close(io);
                var r_b: [10]u8 = undefined;
                var reader = index_file.reader(io, &r_b);
                var idx = reader.interface.takeInt(usize, .big) catch 0;
                idx += 1;
                try writeIndex(index_file, idx, io);
                return idx;
            }

            fn openIndexFile(io: Io) !Io.File {
                log.debug("openIndexFile '{s}' -> '{s}'", .{ @typeName(BaseType), tidx_name });
                return try storage_dir.openFile(io, tidx_name, .{ .mode = .read_write });
            }

            fn createIndexFile(io: Io) !Io.File {
                log.debug("createIndexFile '{s}' -> '{s}'", .{ @typeName(BaseType), tidx_name });
                return try storage_dir.createFile(io, tidx_name, .{});
            }

            pub const scoped = struct {
                var pbuf: [2048]u8 = undefined;

                fn sname(scope: []const u8) []const u8 {
                    return print(&pbuf, "_{s}." ++ tidx_name[1..], .{scope}) catch unreachable;
                }

                fn new(scope: []const u8, io: Io) CommitError!usize {
                    log.err(@typeName(BaseType) ++ ".Index.scoped.next not found, creating", .{});
                    var new_file = storage_dir.createFile(io, sname(scope), .{}) catch @panic("CreateIndexPanic");
                    defer new_file.close(io);
                    try writeIndex(new_file, 1, io);
                    return 1;
                }

                pub fn current(scope: []const u8, io: Io) CommitError!usize {
                    try mutex.lock(io);
                    defer mutex.unlock(io);

                    const index_file = storage_dir.openFile(io, sname(scope), .{}) catch |err| switch (err) {
                        error.FileNotFound => return scoped.new(scope, io),
                        else => {
                            log.err(@typeName(BaseType) ++ ".Index.scoped.next not found {}", .{err});
                            return error.FSError;
                        },
                    };
                    defer index_file.close(io);
                    var r_b: [10]u8 = undefined;
                    var fd_reader = index_file.reader(io, &r_b);
                    var reader = &fd_reader.interface;
                    const idx = reader.takeInt(usize, .big) catch 0;
                    return idx;
                }

                pub fn next(scope: []const u8, io: Io) CommitError!usize {
                    try mutex.lock(io);
                    defer mutex.unlock(io);

                    var index_file = storage_dir.openFile(io, sname(scope), .{ .mode = .read_write }) catch |err| switch (err) {
                        error.FileNotFound => {
                            log.debug(@typeName(BaseType) ++ ".Index.next failed {}", .{err});
                            var new_file = storage_dir.createFile(io, sname(scope), .{}) catch @panic("CreateIndexPanic");
                            defer new_file.close(io);
                            try writeIndex(new_file, 0, io);
                            return 0;
                        },
                        else => {
                            log.err(@typeName(BaseType) ++ ".Index.next failed {}", .{err});
                            return error.FSError;
                        },
                    };
                    defer index_file.close(io);
                    var r_b: [10]u8 = undefined;
                    var reader = index_file.reader(io, &r_b);
                    var idx = reader.interface.takeInt(usize, .big) catch 0;
                    idx += 1;
                    try writeIndex(index_file, idx, io);
                    return idx;
                }
            };
        };

        pub fn read(data: *BaseType, r: *Io.Reader) void {
            return readStruct(BaseType, data, &.{}, r);
        }

        pub fn write(t: *const BaseType, w: *Writer) error{WriteFailed}!void {
            return writeSkip(t, w, &.{});
        }

        pub fn writeSkip(
            t: *const BaseType,
            w: *Writer,
            comptime skips: []const []const u8,
        ) error{WriteFailed}!void {
            log.debug("writing '{s}'", .{@typeName(BaseType)});
            if (@hasDecl(BaseType, "type_prefix") and @hasDecl(BaseType, "type_version")) {
                try w.print("# {s}/{d}\n", .{ @tagName(BaseType.type_prefix), BaseType.type_version });
            }

            try writeStruct(BaseType, t, "", skips, w);
            try w.writeAll("\n");
            try w.flush();
        }

        pub fn iterableDir(io: Io) !Io.Dir {
            return try storage_dir.createDirPathOpen(io, @tagName(type_prefix), .{
                .open_options = .{ .iterate = true },
            });
        }

        pub fn loadData(data: *const BaseType, a: Allocator, io: Io) ReadError!Io.File.Reader {
            log.debug("loadData '{s}'", .{@typeName(BaseType)});
            const file = openFile(data, io) catch |err| {
                log.debug(@typeName(BaseType) ++ " loadData failed: {}", .{err});
                return error.FSError;
            };
            const stat = file.stat(io) catch return error.FSError;
            const buf = try a.alloc(u8, stat.size);
            errdefer a.free(buf);
            log.debug("loadData alloc '{}'", .{stat.size});
            var reader = file.reader(io, buf);
            try reader.interface.fill(stat.size);
            return reader;
        }

        pub fn commit(data: *const BaseType, io: Io) CommitError!void {
            const file = try commitExtra(data, io);
            defer file.file.close(io);
        }

        /// Doesn't close file descriptor
        pub fn commitExtra(data: *const BaseType, io: Io) CommitError!Io.File.Writer {
            return commitExtraSkip(data, io, &.{});
        }

        /// Doesn't close file descriptor
        pub fn commitExtraSkip(
            data: *const BaseType,
            io: Io,
            comptime skips: []const []const u8,
        ) CommitError!Io.File.Writer {
            const file = createFile(data, io) catch return error.FSError;

            var buf: [2048]u8 = undefined;
            var writer = file.writer(io, &buf);
            writeSkip(data, &writer.interface, skips) catch @panic("TODO");
            try writer.interface.flush();
            writer.interface.buffer = &.{};
            return writer;
        }

        fn typedDir(io: Io) !Io.Dir {
            return try storage_dir.createDirPathOpen(io, @tagName(type_prefix), .{});
        }

        fn openFile(data: *const BaseType, io: Io) !Io.File {
            var type_dir = try typedDir(io);
            defer type_dir.close(io);
            return try openFileScoped(data, type_dir, io);
        }

        fn openFileScoped(data: *const BaseType, dest_dir: Io.Dir, io: Io) !Io.File {
            var buf: [2048]u8 = undefined;
            const name = try print(&buf, fmtstr, .{alt(data.*, .typeIdent)});
            log.debug("openFileScoped '{s}' -> '{s}'", .{ @typeName(BaseType), name });
            return try dest_dir.openFile(io, name, .{});
        }

        fn createFile(data: *const BaseType, io: Io) !Io.File {
            var type_dir = try typedDir(io);
            defer type_dir.close(io);
            return createFileScoped(data, type_dir, io);
        }

        fn createFileScoped(data: *const BaseType, dest_dir: Io.Dir, io: Io) !Io.File {
            var buf: [2048]u8 = undefined;
            const name = try print(&buf, fmtstr, .{alt(data.*, .typeIdent)});
            log.debug("createFileScoped '{s}' -> '{s}'", .{ @typeName(BaseType), name });
            return try dest_dir.createFile(io, name, .{});
        }

        fn readStruct(T: type, output: *T, comptime subtype_prefix: []const u8, r: *Io.Reader) void {
            while (r.takeDelimiterInclusive('\n')) |line| {
                if (line.len == 1 and line[0] == '\n') return;
                const name: []u8, const value: [:'\n']u8 = split(line) orelse continue;
                const S = @typeInfo(T).@"struct";
                inline for (S.field_names, S.field_types) |fname, ftype| {
                    const dst = &@field(output, fname);
                    const prefixed_name = if (subtype_prefix.len > 0) subtype_prefix ++ "." ++ fname else fname;
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
                        Thread => dst.* = Thread.fromLine(value) catch unreachable,
                        Delta.Attachment.Kind => dst.* = stringToEnum(ftype, value) orelse dst.*,
                        User.Type => dst.* = stringToEnum(ftype, value) orelse dst.*,
                        CI.Step => dst.* = stringToEnum(ftype, value) orelse dst.*,
                        CI.Result => dst.* = stringToEnum(ftype, value) orelse dst.*,
                        GitSha => dst.* = .init(value),

                        std.debug.SafetyLock => unreachable,
                        std.debug.SafetyLock.State => unreachable,

                        ?Io.File,
                        ?Io.Writer,
                        []const Gist.File, // Managed internally by Gist
                        ArrayList(Message), // Managed internally by Threads
                        ArrayList(Viewers.View), // Managed internally by Viewers
                        ArrayList(CI.Step), // Managed internally by CI
                        => if (comptime type_debugging) log.info(
                            "building {s} reader skipped `{s}: {s}` (intentionally skipped)",
                            .{ @typeName(T), fname, @typeName(ftype) },
                        ),
                        else => switch (@typeInfo(ftype)) {
                            .@"enum" => |enumT| {
                                if (enumT.mode == .nonexhaustive)
                                    @compileError(
                                        subtype_prefix ++
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
                        .@"struct" => if (comptime custom_types.contains(ftype)) {
                            const save = r.seek;
                            r.seek -|= line.len;
                            readStruct(ftype, dst, fname, r);
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
        }

        fn omitable(name: []const u8, omits: []const []const u8) bool {
            inline for (omits) |omit| {
                if (eql(u8, name, omit)) return true;
            }
            return false;
        }

        fn writeStruct(
            T: type,
            t: *const T,
            comptime name: []const u8,
            comptime omits: []const []const u8,
            w: *Writer,
        ) error{WriteFailed}!void {
            const S = @typeInfo(T).@"struct";
            inline for (S.field_names, S.field_types) |fname, ftype| {
                // TODO remove this hack
                if (comptime @hasDecl(BaseType, "type_skip_fields"))
                    @compileError("remove type skip hack");

                if (comptime omitable(fname, omits)) continue;

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
                    Thread => try w.print("{s}: {f}\n", .{ fname, src.* }),
                    Delta.Attachment.Kind => try w.print("{s}: {s}\n", .{ fname, @tagName(src.*) }),
                    User.Type => try w.print("{s}: {s}\n", .{ fname, @tagName(src.*) }),
                    CI.Step => try w.print("{s}: {s}\n", .{ fname, @tagName(src.*) }),
                    CI.Result => try w.print("{s}: {s}\n", .{ fname, @tagName(src.*) }),
                    GitSha => try w.print("{s}: {f}\n", .{ fname, std.fmt.alt(src.*, .fmtHex) }),

                    ?Io.File,
                    ?Io.Writer,
                    []const Gist.File, // Managed internally by Gist
                    ArrayList(Message), // Managed internally by Threads
                    ArrayList(Viewers.View), // Managed internally by Viewers
                    ArrayList(CI.Step), // Managed internally by CI
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
                                try writeStruct(ftype, src, prefix, omits, w);
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

test types {
    _ = &common;
    _ = &Artifact;
    _ = &CI;
    _ = &Delta;
    _ = &Diff;
    _ = &Gist;
    _ = &Message;
    _ = &Network;
    _ = &RepoMeta;
    _ = &Tags;
    _ = &Thread;
    _ = &User;
    _ = &Viewers;
}

const common = @import("types/common.zig");
const std = @import("std");
const log = std.log.scoped(.srctypes);
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Reader = Io.File.Reader;
const fs = std.fs;
const parseInt = std.fmt.parseInt;
const indexOf = std.mem.indexOf;
const splitScalar = std.mem.splitScalar;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const print = std.fmt.bufPrint;
const stringToEnum = std.meta.stringToEnum;
const git = @import("git.zig");
const alt = std.fmt.alt;

const type_debugging = false;
