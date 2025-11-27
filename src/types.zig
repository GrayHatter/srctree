pub const Message = @import("types/message.zig");
pub const CommitMap = @import("types/commit-map.zig");
pub const Delta = @import("types/delta.zig");
pub const Diff = @import("types/diff.zig");
pub const Gist = @import("types/gist.zig");
pub const Issue = @import("types/issue.zig");
pub const Network = @import("types/network.zig");
pub const Tags = @import("types/tags.zig");
pub const Thread = @import("types/thread.zig");
pub const User = @import("types/user.zig");
pub const Viewers = @import("types/viewers.zig");

pub const DefaultHash = [sha256.digest_length]u8;
pub const DefaultHasher = std.crypto.hash.sha2.Sha256;
pub const Sha1Hex = [40]u8;

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

var storage_dir: Storage = undefined;

pub fn init(dir: Storage, io: Io) !void {
    storage_dir = dir;
    inline for (.{
        Message,
        CommitMap,
        Delta,
        Diff,
        Gist,
        Issue,
        Network,
        Thread,
        User,
    }) |inc| {
        if (@hasDecl(inc, "initType") and @hasDecl(inc, "TYPE_PREFIX")) {
            try inc.initType(try dir.makeOpenPath(io, inc.TYPE_PREFIX, .{ .iterate = true }));
        }
    }
}

pub fn raze(io: Io) void {
    storage_dir.close(io);
}

pub fn iterableDir(comptime type_name: @TypeOf(.enum_literal), io: Io) !Io.Dir {
    return try storage_dir.makeOpenPath(io, @tagName(type_name), .{ .iterate = true });
}

pub fn loadDataAlloc(comptime type_name: @TypeOf(.enum_literal), name: []const u8, a: Allocator, io: Io) ![]u8 {
    var type_dir = try storage_dir.makeOpenPath(io, @tagName(type_name), .{});
    defer type_dir.close(io);
    const file = try type_dir.openFile(io, name, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try a.alloc(u8, stat.size);
    errdefer a.free(buf);
    var reader = file.reader(io, buf);
    try reader.interface.fill(stat.size);
    return buf;
}

pub fn loadDataReader(comptime type_name: @TypeOf(.enum_literal), name: []const u8, a: Allocator, io: Io) !Reader {
    var type_dir = try storage_dir.makeOpenPath(io, @tagName(type_name), .{});
    defer type_dir.close(io);
    const file = try type_dir.openFile(io, name, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try a.alloc(u8, stat.size);
    errdefer a.free(buf);
    var reader = file.reader(io, buf);
    try reader.interface.fill(stat.size);
    return reader;
}

pub fn commit(comptime type_name: @TypeOf(.enum_literal), name: []const u8, io: Io) !fs.File {
    var type_dir = try storage_dir.makeOpenPath(io, @tagName(type_name), .{});
    defer type_dir.close(io);
    const new = try type_dir.createFile(io, name, .{});
    return .adaptFromNewApi(new);
}

pub fn currentIndex(comptime type_name: @TypeOf(.enum_literal), io: Io) !usize {
    const name = "_" ++ @tagName(type_name) ++ ".index";
    var index_file = storage_dir.openFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            var new_file = try storage_dir.createFile(io, name, .{});
            defer new_file.close(io);
            try incrementIndex(new_file, 0, io);
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

fn incrementIndex(fd: Io.File, idx: usize, _: Io) !void {
    var new: fs.File = .adaptFromNewApi(fd);
    var writer = new.writer(&.{});
    try writer.interface.writeInt(usize, idx, .big);
    try writer.interface.flush();
}

pub fn nextIndex(comptime type_name: @TypeOf(.enum_literal), io: Io) !usize {
    const name = "_" ++ @tagName(type_name) ++ ".index";
    var index_file = try storage_dir.createFile(io, name, .{ .read = true, .truncate = false });
    defer index_file.close(io);
    var r_b: [10]u8 = undefined;
    var reader = index_file.reader(io, &r_b);
    var idx = reader.interface.takeInt(usize, .big) catch 0;
    idx += 1;
    try incrementIndex(index_file, idx, io);
    return idx;
}

pub fn currentIndexNamed(comptime type_name: @TypeOf(.enum_literal), extra_name: []const u8, io: Io) !usize {
    var buffer: [2048]u8 = undefined;
    const name = try std.fmt.bufPrint(&buffer, "_{s}.{s}.index", .{
        extra_name,
        @tagName(type_name),
    });
    var index_file = storage_dir.openFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            var new_file = try storage_dir.createFile(io, name, .{});
            defer new_file.close(io);
            try incrementIndex(new_file, 0, io);
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

pub fn nextIndexNamed(comptime type_name: @TypeOf(.enum_literal), extra_name: []const u8, io: Io) !usize {
    var buffer: [2048]u8 = undefined;
    const name = try std.fmt.bufPrint(&buffer, "_{s}.{s}.index", .{
        extra_name,
        @tagName(type_name),
    });
    var index_file = try storage_dir.createFile(io, name, .{ .read = true, .truncate = false });
    defer index_file.close(io);
    var r_b: [10]u8 = undefined;
    var reader = index_file.reader(io, &r_b);
    var idx = reader.interface.takeInt(usize, .big) catch 0;
    idx += 1;
    try incrementIndex(index_file, idx, io);
    return idx;
}

pub fn split(line: []u8) ?struct { []u8, []u8 } {
    const idx = indexOf(u8, line, ": ") orelse return null;
    std.debug.assert(line[line.len - 1] == '\n');
    return .{ line[0..idx], line[idx + 2 .. line.len - 1] };
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

                inline for (@typeInfo(T).@"struct".fields) |field| {
                    const name, const value: []u8 = split(line) orelse break;
                    const field_name = if (prefix.len > 0) prefix ++ "." ++ field.name else field.name;
                    if (eql(u8, name, field_name)) switch (field.type) {
                        DefaultHash => {
                            if (value.len == 64) {
                                var hex: []const u8 = value;
                                for (0..32) |i| {
                                    @field(output, field.name)[i] = parseInt(u8, hex[0..2], 16) catch 0;
                                    hex = hex[2..];
                                }
                            }
                        },
                        Sha1Hex => {
                            if (value.len == 40) {
                                @memcpy(@field(output, field.name)[0..40], value[0..40]);
                            }
                        },
                        []u8, []const u8, ?[]const u8 => {
                            for (value) |*chr| {
                                if (chr.* == 0x1a) chr.* = '\n';
                            }
                            @field(output, field.name) = value;
                        },
                        usize => @field(output, field.name) = parseInt(usize, value, 10) catch @field(output, field.name),
                        i64 => @field(output, field.name) = parseInt(i64, value, 10) catch @field(output, field.name),
                        i32 => @field(output, field.name) = parseInt(i32, value, 10) catch @field(output, field.name),
                        bool => @field(output, field.name) = eql(u8, value, "true"),
                        VarString(128) => @field(output, field.name) = VarString(128).init(value),
                        VarString(256) => @field(output, field.name) = VarString(256).init(value),
                        else => switch (@typeInfo(field.type)) {
                            .@"enum" => |enumT| {
                                if (!enumT.is_exhaustive) @compileError("non-exaustive enums are not supported");
                                if (std.meta.stringToEnum(field.type, value)) |enumV| {
                                    @field(output, field.name) = enumV;
                                }
                            },
                            else => if (comptime type_debugging)
                                log.err("skipped type {s} on {s}", .{ @typeName(field.type), @typeName(T) }),
                        },
                    } else if (startsWith(u8, name, field.name)) switch (@typeInfo(field.type)) {
                        .@"struct" => {
                            const save = r.seek;
                            @field(output, field.name) = readStruct(field.type, @field(output, field.name), field.name, r);
                            r.seek = save;
                        },
                        else => {},
                    };
                }
            } else |_| log.err("incomplete read", .{});

            return output;
        }

        pub fn write(t: *const BaseType, w: *Writer) error{WriteFailed}!void {
            if (@hasDecl(BaseType, "type_prefix") and @hasDecl(BaseType, "type_version")) {
                try w.print("# {s}/{d}\n", .{ BaseType.type_prefix, BaseType.type_version });
            }

            try writeStruct(BaseType, t, "", w);
            try w.writeAll("\n");
            try w.flush();
        }

        fn writeStruct(T: type, t: *const T, comptime name: []const u8, w: *Writer) error{WriteFailed}!void {
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (name.len > 0) try w.writeAll(name ++ ".");

                switch (field.type) {
                    []u8,
                    []const u8,
                    ?[]const u8,
                    VarString(128),
                    VarString(256),
                    => |kind| {
                        const value: ?[]const u8 = switch (kind) {
                            []u8, []const u8, ?[]const u8 => @field(t, field.name),
                            VarString(128), VarString(256) => @field(t, field.name).slice(),
                            else => comptime unreachable,
                        };
                        if (value) |v| {
                            try w.print("{s}: ", .{field.name});
                            var itr = splitScalar(u8, v, '\n');
                            while (itr.next()) |line| {
                                try w.writeAll(line);
                                if (itr.peek()) |_| try w.writeAll("\x1a");
                            }
                            try w.writeAll("\n");
                        }
                    },

                    DefaultHash => try w.print("{s}: {x}\n", .{ field.name, &@field(t, field.name) }),
                    Sha1Hex => try w.print("{s}: {s}\n", .{ field.name, &@field(t, field.name) }),
                    usize,
                    isize,
                    i64,
                    i32,
                    => try w.print("{s}: {d}\n", .{ field.name, @field(t, field.name) }),
                    bool => try w.print("{s}: {s}\n", .{ field.name, if (@field(t, field.name)) "true" else "false" }),
                    else => switch (@typeInfo(field.type)) {
                        .@"enum" => |enumT| {
                            if (!enumT.is_exhaustive) @compileError("non-exaustive enums are not supported");
                            try w.print("{s}: {s}\n", .{ field.name, @tagName(@field(t, field.name)) });
                        },
                        .@"struct" => |_| {
                            const prefix = if (name.len > 0) name ++ "." ++ field.name else field.name;
                            try writeStruct(field.type, &@field(t, field.name), prefix, w);
                        },
                        else => if (comptime type_debugging)
                            log.err("skipped type {s} on {s}", .{ @typeName(field.type), @typeName(T) }),
                    },
                }
            }
        }
    };
}

const std = @import("std");
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

const sha256 = std.crypto.hash.sha2.Sha256;
// TODO buildtime const/flag
const type_debugging = false;
