pub const Message = @import("types/message.zig");
pub const CommitMap = @import("types/commit-map.zig");
pub const Delta = @import("types/delta.zig");
pub const Diff = @import("types/diff.zig");
pub const Gist = @import("types/gist.zig");
pub const Issue = @import("types/issue.zig");
pub const Network = @import("types/network.zig");
pub const Read = @import("types/read.zig");
pub const Tags = @import("types/tags.zig");
pub const Thread = @import("types/thread.zig");
pub const User = @import("types/user.zig");
pub const Viewers = @import("types/viewers.zig");

pub const DefaultHash = [sha256.digest_length]u8;
pub const DefaultHasher = std.crypto.hash.sha2.Sha256;
pub const Sha1Hex = [40]u8;

pub const Storage = std.fs.Dir;

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

pub fn init(dir: Storage) !void {
    storage_dir = dir;
    inline for (.{
        Message,
        CommitMap,
        Delta,
        Diff,
        Gist,
        Issue,
        Network,
        Read,
        Thread,
        User,
    }) |inc| {
        if (@hasDecl(inc, "initType") and @hasDecl(inc, "TYPE_PREFIX")) {
            try inc.initType(try dir.makeOpenPath(inc.TYPE_PREFIX, .{ .iterate = true }));
        }
    }
}

pub fn raze() void {
    storage_dir.close();
}

pub fn iterableDir(comptime type_name: @TypeOf(.enum_literal)) !std.fs.Dir {
    return try storage_dir.makeOpenPath(@tagName(type_name), .{ .iterate = true });
}

pub fn loadData(comptime type_name: @TypeOf(.enum_literal), a: Allocator, name: []const u8) ![]u8 {
    var type_dir = try storage_dir.makeOpenPath(@tagName(type_name), .{});
    defer type_dir.close();
    return try type_dir.readFileAlloc(a, name, 0x8ffff);
}

pub fn commit(comptime type_name: @TypeOf(.enum_literal), name: []const u8) !std.fs.File {
    var type_dir = try storage_dir.makeOpenPath(@tagName(type_name), .{});
    defer type_dir.close();
    return try type_dir.createFile(name, .{});
}

pub fn currentIndex(comptime type_name: @TypeOf(.enum_literal)) !usize {
    const name = "_" ++ @tagName(type_name) ++ ".index";
    var index_file = storage_dir.openFile(name, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            var new_file = try storage_dir.createFile(name, .{});
            defer new_file.close();
            var fd_writer = new_file.writer(&.{});
            const writer = &fd_writer.interface;
            try writer.writeInt(usize, 0, .big);
            try writer.flush();
            return 0;
        },
        else => return err,
    };
    defer index_file.close();
    var r_b: [10]u8 = undefined;
    var fd_reader = index_file.reader(&r_b);
    const reader = &fd_reader.interface;
    const idx = reader.takeInt(usize, .big) catch 0;
    return idx;
}

pub fn nextIndex(comptime type_name: @TypeOf(.enum_literal)) !usize {
    const name = "_" ++ @tagName(type_name) ++ ".index";
    var index_file = try storage_dir.createFile(name, .{ .read = true, .truncate = false });
    defer index_file.close();
    var r_b: [10]u8 = undefined;
    var fd_reader = index_file.reader(&r_b);
    const reader = &fd_reader.interface;
    var idx = reader.takeInt(usize, .big) catch 0;
    idx += 1;
    try index_file.seekTo(0);
    var fd_writer = index_file.writer(&.{});
    const writer = &fd_writer.interface;
    try writer.writeInt(usize, idx, .big);
    try writer.flush();
    return idx;
}

pub fn currentIndexNamed(comptime type_name: @TypeOf(.enum_literal), extra_name: []const u8) !usize {
    var buffer: [2048]u8 = undefined;
    const name = try std.fmt.bufPrint(&buffer, "_{s}.{s}.index", .{
        extra_name,
        @tagName(type_name),
    });
    var index_file = storage_dir.openFile(name, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            var new_file = try storage_dir.createFile(name, .{});
            defer new_file.close();
            var fd_writer = new_file.writer(&.{});
            const writer = &fd_writer.interface;
            try writer.writeInt(usize, 0, .big);
            try writer.flush();
            return 0;
        },
        else => return err,
    };
    defer index_file.close();
    var r_b: [10]u8 = undefined;
    var fd_reader = index_file.reader(&r_b);
    var reader = &fd_reader.interface;
    const idx = reader.takeInt(usize, .big) catch 0;
    return idx;
}

pub fn nextIndexNamed(comptime type_name: @TypeOf(.enum_literal), extra_name: []const u8) !usize {
    var buffer: [2048]u8 = undefined;
    const name = try std.fmt.bufPrint(&buffer, "_{s}.{s}.index", .{
        extra_name,
        @tagName(type_name),
    });
    var index_file = try storage_dir.createFile(name, .{ .read = true, .truncate = false });
    defer index_file.close();
    var r_b: [10]u8 = undefined;
    var fd_reader = index_file.reader(&r_b);
    const reader = &fd_reader.interface;
    var idx = reader.takeInt(usize, .big) catch 0;
    idx += 1;
    try index_file.seekTo(0);
    var fd_writer = index_file.writer(&.{});
    const writer = &fd_writer.interface;
    try writer.writeInt(usize, idx, .big);
    try writer.flush();
    return idx;
}

pub fn split(line: []u8) ?struct { []u8, []u8 } {
    const idx = std.mem.indexOf(u8, line, ": ") orelse return null;
    return .{ line[0..idx], line[idx + 2 ..] };
}

pub fn readerWriter(T: type, default: T) type {
    return struct {
        pub fn read(data: []u8) T {
            if (data.len == 0) return default;
            const header_end = std.mem.indexOf(u8, data, "\n\n") orelse data.len;
            const header = data[0..header_end];
            var line_itr = std.mem.splitScalar(u8, header, '\n');
            var output: T = default;
            var line: []u8 = @constCast(line_itr.first());
            var reset = false;

            inline for (@typeInfo(T).@"struct".fields) |field| {
                reset = false;
                while (!std.mem.startsWith(u8, line, field.name)) {
                    line = @constCast(line_itr.next()) orelse orel: {
                        if (reset) break;
                        reset = true;
                        line_itr.reset();
                        break :orel @constCast(line_itr.first());
                    };
                    reset = true;
                }
                if (line_itr.index != 0) {
                    const name, const value: []u8 = split(line) orelse .{ &.{}, &.{} };
                    if (std.mem.eql(u8, name, field.name)) switch (field.type) {
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
                        bool => @field(output, field.name) = std.mem.eql(u8, value, "true"),
                        VarString(128) => @field(output, field.name) = VarString(128).init(value),
                        VarString(256) => @field(output, field.name) = VarString(256).init(value),
                        else => switch (@typeInfo(field.type)) {
                            .@"enum" => |enumT| {
                                if (!enumT.is_exhaustive) @compileError("non-exaustive enums are not supported");
                                if (std.meta.stringToEnum(field.type, value)) |enumV| {
                                    @field(output, field.name) = enumV;
                                }
                            },
                            else => {
                                if (comptime type_debugging) std.debug.print("skipped type {s} on {s}\n", .{ @typeName(field.type), @typeName(T) });
                            },
                        },
                    };
                }
            }
            return output;
        }

        pub fn write(t: *const T, w: *Writer) error{WriteFailed}!void {
            if (@hasDecl(T, "type_prefix") and @hasDecl(T, "type_version")) {
                try w.print("# {s}/{d}\n", .{ T.type_prefix, T.type_version });
            }

            inline for (@typeInfo(T).@"struct".fields) |field| {
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
                            var itr = std.mem.splitScalar(u8, v, '\n');
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
                        else => {
                            if (comptime type_debugging) std.debug.print("skipped type {s} on {s}\n", .{ @typeName(field.type), @typeName(T) });
                        },
                    },
                }
            }
            try w.writeAll("\n");
            try w.flush();
        }
    };
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const parseInt = std.fmt.parseInt;
const sha256 = std.crypto.hash.sha2.Sha256;
// TODO buildtime const/flag
const type_debugging = false;
