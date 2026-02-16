const Setting = struct {
    name: []const u8,
    val: []const u8,

    // str must outlive Setting
    fn init(str: []const u8) Setting {
        if (findScalar(u8, str, '=')) |i| {
            return .{
                .name = trim(u8, str[0..i], " \t"),
                .val = trim(u8, str[i + 1 ..], " \t"),
            };
        }
        unreachable;
    }

    pub fn format(setting: Setting, w: *Writer) !void {
        try w.print("{s} = {s}", .{ setting.name, setting.val });
    }
};

pub const Namespace = struct {
    name: []const u8,
    settings: []const Setting,

    /// Name must outlive the Namespace
    pub fn init(name: []const u8, r: *Reader, a: Allocator) !Namespace {
        var list: ArrayList(Setting) = .{};
        errdefer list.deinit(a);

        while (r.takeSentinel('\n')) |wide| {
            const line = trim(u8, wide, " \t");
            if (line.len > 3 and line[0] != '#' and find(u8, line, "=") != null) {
                try list.append(a, .init(line));
            }
            if (r.peekSentinel('\n')) |peekW| {
                const peek = trim(u8, peekW, " \t");
                if (peek.len > 0 and peek[0] == '[') break;
            } else |_| break;
        } else |e| switch (e) {
            error.EndOfStream => {},
            else => return e,
        }

        return .{
            .name = name[1 .. name.len - 1],
            .settings = try list.toOwnedSlice(a),
        };
    }

    pub fn get(self: Namespace, name: []const u8) ?[]const u8 {
        for (self.settings) |st| {
            if (eql(u8, name, st.name)) return st.val;
        }
        return null;
    }

    pub fn getBool(self: Namespace, name: []const u8) ?bool {
        const set: []const u8 = self.get(name) orelse return null;
        if (set.len > 5) return null;
        if (eql(u8, set, "0") or eqlCaseless(set, "false") or eqlCaseless(set, "f")) {
            return false;
        } else if (eql(u8, set, "1") or eqlCaseless(set, "true") or eqlCaseless(set, "t")) {
            return true;
        } else return null;
    }

    pub fn format(ns: Namespace, w: *Writer) !void {
        for (ns.settings) |setting|
            try w.print("    {f}\n", .{setting});
    }

    pub fn raze(ns: Namespace, a: Allocator) void {
        a.free(ns.settings);
    }
};

pub fn Config(BaseT: type) type {
    return struct {
        config: Base,
        ini: IniData,

        pub const Self = @This();

        pub const Base = BaseT;

        pub const IniData = struct {
            ns: []Namespace,

            pub const empty: IniData = .{ .ns = &.{} };

            pub fn filter(ini: IniData, prefix: []const u8, index: usize) ?Namespace {
                var remaining = index;
                for (ini.ns) |ns| {
                    if (startsWith(u8, ns.name, prefix)) {
                        if (remaining == 0) return ns;
                        remaining -= 1;
                    }
                } else return null;
            }

            pub fn get(ini: IniData, name: []const u8) ?Namespace {
                for (ini.ns) |ns| {
                    if (eql(u8, ns.name, name)) {
                        return ns;
                    }
                }
                return null;
            }

            fn buildStruct(ini: IniData, T: type, name: []const u8) !?T {
                if (T == void) return {};
                var namespace: T = undefined;
                const ns = ini.get(name) orelse return null;
                inline for (@typeInfo(T).@"struct".fields) |s| {
                    @field(namespace, s.name) = switch (s.type) {
                        bool => ns.getBool(s.name) orelse s.defaultValue() orelse return error.SettingMissing,
                        ?bool => ns.getBool(s.name),
                        []const u8 => ns.get(s.name) orelse return error.SettingMissing,
                        ?[]const u8 => ns.get(s.name),
                        else => @compileError("not implemented"),
                    };
                }
                return namespace;
            }
        };

        fn makeBase(self: IniData) !Base {
            if (Base == void) return {};
            var base: Base = undefined;
            inline for (@typeInfo(Base).@"struct".fields) |f| {
                if (f.type == []const u8) comptime unreachable; // Root variable not yet supported
                @field(base, f.name) = switch (@typeInfo(f.type)) {
                    .@"struct" => try self.buildStruct(f.type, f.name) orelse return error.NamespaceMissing,
                    .optional => self.buildStruct(@typeInfo(f.type).optional.child, f.name) catch null,
                    else => @compileError("not implemented"),
                };
            }

            return base;
        }

        pub fn init(r: *Reader, a: Allocator) !Self {
            var list: ArrayList(Namespace) = .{};
            errdefer {
                for (list.items) |itm| itm.raze(a);
                list.deinit(a);
            }

            while (r.takeSentinel('\n')) |wide| {
                const line = trim(u8, wide, " \t");
                if (line.len == 0) continue;

                if (line[0] == '[' and line[line.len - 1] == ']') {
                    try list.append(a, try .init(line, r, a));
                }
            } else |e| switch (e) {
                error.EndOfStream => {},
                else => return e,
            }

            const ini: IniData = .{
                .ns = try list.toOwnedSlice(a),
            };

            return .{
                .config = try makeBase(ini),
                .ini = ini,
            };
        }

        pub fn raze(self: Self, a: Allocator) void {
            for (self.ini.ns) |ns| ns.raze(a);
            a.free(self.ini.ns);
        }

        pub fn save(self: Self, w: *Writer) !void {
            try w.print("{f}\n", .{self});
        }

        pub fn format(self: Self, w: *Writer) !void {
            for (self.ini.ns) |ns| {
                try w.print("[{s}]\n{f}", .{ ns.name, ns });
            }
        }
    };
}

test "default" {
    const a = std.testing.allocator;

    const expected: Config(void) = .{
        .config = {},
        .ini = .{
            .ns = @constCast(&[1]Namespace{.{
                .name = "one",
                .settings = @constCast(&[1]Setting{
                    .{ .name = "left", .val = "right" },
                }),
            }}),
        },
    };

    var r: Reader = .fixed("[one]\nleft = right\n");

    const vtest = try Config(void).init(&r, a);
    defer vtest.raze(a);

    try std.testing.expectEqualDeep(expected, vtest);
}

test "getBool" {
    const data =
        \\[test data]
        \\first = true
        \\second = t
        \\third=1
        \\forth=0
        \\fifth = false
        \\sixth = FALSE
        \\seventh = f
        \\ eight = 0
        \\    ninth = F
    ++ "       \n" ++ // intentional trailing spaces
        \\tenth = failure
        \\
    ;
    // eight & ninth are expected to have leading & trailing whitespace

    const Cfg = Config(struct {});

    const a = std.testing.allocator;
    var r: Reader = .fixed(data);
    const c = try Cfg.init(&r, a);
    defer c.raze(a);
    const ns = c.ini.get("test data").?;

    try std.testing.expectEqual(true, ns.getBool("first").?);
    try std.testing.expectEqual(true, ns.getBool("second").?);
    try std.testing.expectEqual(true, ns.getBool("third").?);
    try std.testing.expectEqual(false, ns.getBool("forth").?);
    try std.testing.expectEqual(false, ns.getBool("fifth").?);
    try std.testing.expectEqual(false, ns.getBool("sixth").?);
    try std.testing.expectEqual(false, ns.getBool("seventh").?);
    try std.testing.expectEqual(false, ns.getBool("eight").?);
    try std.testing.expectEqual(false, ns.getBool("ninth").?);
    try std.testing.expectEqual(null, ns.getBool("tenth"));
}

test "commented" {
    const a = std.testing.allocator;

    const vut =
        \\[open]
        \\left = right
        \\#comment = ignored
        \\    # long_comment = still_ignored
        \\ this = works
        \\ # but not this
    ;

    const expected: Config(void) = .{
        .config = {},
        .ini = .{
            .ns = @constCast(&[1]Namespace{.{
                .name = "open",
                .settings = @constCast(&[2]Setting{
                    .{ .name = "left", .val = "right" },
                    .{ .name = "this", .val = "works" },
                }),
            }}),
        },
    };

    var r: Reader = .fixed(vut);

    const vtest = try Config(void).init(&r, a);
    defer vtest.raze(a);

    try std.testing.expectEqualDeep(expected, vtest);

    var w: Writer.Allocating = try .initCapacity(a, 256);
    defer w.deinit();
    try w.writer.print("{f}", .{vtest});
    try std.testing.expectEqualStrings(
        \\[open]
        \\    left = right
        \\    this = works
        \\
    , w.writer.buffered());
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const eqlCaseless = std.ascii.eqlIgnoreCase;
const find = std.mem.find;
const findScalar = std.mem.findScalar;
const startsWith = std.mem.startsWith;
const trim = std.mem.trim;
