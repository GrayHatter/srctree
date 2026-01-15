const Setting = struct {
    name: []const u8,
    val: []const u8,

    // str must outlive Setting
    fn init(str: []const u8) Setting {
        if (findScalar(u8, str, '=')) |i| {
            return .{
                .name = trim(u8, str[0..i], " \n\t"),
                .val = trim(u8, str[i + 1 ..], " \n\t"),
            };
        }
        unreachable;
    }
};

pub const Namespace = struct {
    name: []const u8,
    settings: []const Setting,
    block: []const u8,

    /// Name must outlive the Namespace
    pub fn init(a: Allocator, name: []const u8, itr: *ScalarIter) !Namespace {
        var list: ArrayList(Setting) = .{};
        errdefer list.deinit(a);

        const ns_start = itr.index.?;

        while (itr.next()) |next| {
            const line = trim(u8, next, " \n\t");
            if (line.len > 3 and line[0] != '#' and find(u8, line, "=") != null) {
                try list.append(a, .init(line));
            }
            if (itr.peek()) |peekW| {
                const peek = trim(u8, peekW, " \t");
                if (peek.len > 0 and peek[0] == '[') break;
            }
        }

        return .{
            .name = name[1 .. name.len - 1],
            .settings = try list.toOwnedSlice(a),
            .block = itr.buffer[ns_start .. itr.index orelse itr.buffer.len],
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

    pub fn raze(ns: Namespace, a: Allocator) void {
        a.free(ns.settings);
    }
};

pub const Any = Config(void);

pub fn Config(BaseT: type) type {
    return struct {
        config: Base,
        ctx: IniData,

        pub const Self = @This();

        pub const Base = BaseT;

        pub const IniData = struct {
            ns: []Namespace,
            data: []const u8,
            owned: ?[]const u8 = null,

            pub const empty: IniData = .{
                .ns = &.{},
                .data = &.{},
            };

            pub fn filter(ctx: IniData, prefix: []const u8, index: usize) ?Namespace {
                var remaining = index;
                for (ctx.ns) |ns| {
                    if (startsWith(u8, ns.name, prefix)) {
                        if (remaining == 0) return ns;
                        remaining -= 1;
                    }
                } else return null;
            }

            pub fn get(ctx: IniData, name: []const u8) ?Namespace {
                for (ctx.ns) |ns| {
                    if (eql(u8, ns.name, name)) {
                        return ns;
                    }
                }
                return null;
            }

            fn buildStruct(ctx: IniData, T: type, name: []const u8) !?T {
                if (T == void) return {};
                var namespace: T = undefined;
                const ns = ctx.get(name) orelse return null;
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

        pub fn raze(self: Self, a: Allocator) void {
            for (self.ctx.ns) |ns| ns.raze(a);
            a.free(self.ctx.ns);
            if (self.ctx.owned) |owned| a.free(owned);
        }

        /// `data` must outlive returned object
        pub fn init(a: Allocator, data: []const u8) !Self {
            var itr = splitScalar(u8, data, '\n');

            var list: ArrayList(Namespace) = .{};
            errdefer {
                for (list.items) |itm| itm.raze(a);
                list.deinit(a);
            }

            while (itr.next()) |wide| {
                const line = trim(u8, wide, " \n\t");
                if (line.len == 0) continue;

                if (line[0] == '[' and line[line.len - 1] == ']') {
                    try list.append(a, try .init(a, line, &itr));
                }
            }

            const ctx: IniData = .{
                .ns = try list.toOwnedSlice(a),
                .data = data,
                .owned = null,
            };

            return .{
                .config = try makeBase(ctx),
                .ctx = ctx,
            };
        }

        pub fn fromFile(a: Allocator, io: std.Io, file: std.Io.File) !Self {
            var r_b: [2048]u8 = undefined;
            var reader = file.reader(io, &r_b);
            const data = try reader.interface.allocRemaining(a, .limited(0x8000));

            var self: Self = try init(a, data);
            self.ctx.owned = data;
            return self;
        }
    };
}

test "default" {
    const a = std.testing.allocator;

    const expected: Config(void) = .{
        .config = {},
        .ctx = .{
            .ns = @constCast(&[1]Namespace{.{
                .name = "one",
                .settings = @constCast(&[1]Setting{
                    .{ .name = "left", .val = "right" },
                }),
                .block = @constCast("left = right"),
            }}),
            .data = @constCast("[one]\nleft = right"),
        },
    };

    const vtest = try Config(void).init(a, "[one]\nleft = right");
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
    const c = try Cfg.init(a, data);
    defer c.raze(a);
    const ns = c.ctx.get("test data").?;

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
        .ctx = .{
            .ns = @constCast(&[1]Namespace{.{
                .name = "open",
                .settings = @constCast(&[2]Setting{
                    .{ .name = "left", .val = "right" },
                    .{ .name = "this", .val = "works" },
                }),
                .block = @constCast(vut[7..]),
            }}),
            .data = @constCast(vut),
        },
    };

    const vtest = try Config(void).init(a, vut);
    defer vtest.raze(a);

    try std.testing.expectEqualDeep(expected, vtest);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ScalarIter = std.mem.SplitIterator(u8, .scalar);
const eql = std.mem.eql;
const eqlCaseless = std.ascii.eqlIgnoreCase;
const find = std.mem.find;
const findScalar = std.mem.findScalar;
const splitScalar = std.mem.splitScalar;
const startsWith = std.mem.startsWith;
const trim = std.mem.trim;
