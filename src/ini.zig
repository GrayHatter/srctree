const Setting = struct {
    name: []const u8,
    val: []const u8,

    fn pair(a: Allocator, str: []const u8) !Setting {
        if (indexOfScalar(u8, str, '=')) |i| {
            return .{
                .name = try a.dupe(u8, trim(u8, str[0..i], " \n\t")),
                .val = try a.dupe(u8, trim(u8, str[i + 1 ..], " \n\t")),
            };
        }
        unreachable;
    }

    fn raze(s: Setting, a: Allocator) void {
        a.free(s.name);
        a.free(s.val);
    }
};

pub const Namespace = struct {
    name: []u8,
    settings: []Setting,
    block: []const u8,

    pub fn init(a: Allocator, name: []const u8, itr: *ScalarIter) !Namespace {
        var list: std.ArrayList(Setting) = .{};
        errdefer {
            for (list.items) |itm| itm.raze(a);
            list.deinit(a);
        }
        const ns_start = itr.index.?;
        const ns_block = itr.buffer[ns_start..];

        while (itr.peek()) |peek| {
            const line = trim(u8, peek, " \n\t");
            if (line.len < 3 or line[0] == '#') {
                _ = itr.next();
                continue;
            }
            if (line[0] == '[') break;
            if (count(u8, line, "=") == 0) {
                _ = itr.next();
                continue;
            }
            const pair = try Setting.pair(a, line);
            try list.append(a, pair);
            _ = itr.next();
        }

        const ns_end = itr.index orelse itr.buffer.len;
        return .{
            .name = try a.dupe(u8, name[1 .. name.len - 1]),
            .settings = try list.toOwnedSlice(a),
            .block = ns_block[0 .. ns_end - ns_start],
        };
    }

    pub fn get(self: Namespace, name: []const u8) ?[]const u8 {
        for (self.settings) |st| {
            if (eql(u8, name, st.name)) {
                return st.val;
            }
        }
        return null;
    }

    pub fn getBool(self: Namespace, name: []const u8) ?bool {
        const set: []const u8 = self.get(name) orelse return null;
        if (set.len > 5) return null;
        var buffer: [6]u8 = undefined;
        const check = lowerString(buffer[0..], set);
        if (eql(u8, check, "false") or eql(u8, check, "0") or eql(u8, check, "f")) {
            return false;
        } else if (eql(u8, check, "true") or eql(u8, check, "1") or eql(u8, check, "t")) {
            return true;
        } else return null;
    }

    pub fn raze(self: Namespace, a: Allocator) void {
        a.free(self.name);
        for (self.settings) |set| {
            set.raze(a);
        }
        a.free(self.settings);
    }
};

pub fn Config(B: anytype) type {
    return struct {
        config: Base,
        ctx: IniData,

        pub const Base = B;

        pub const IniData = struct {
            ns: []Namespace,
            data: []const u8,
            owned: ?[]const u8,

            pub const empty: IniData = .{
                .ns = &.{},
                .data = &.{},
                .owned = null,
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
                    switch (s.type) {
                        bool => {
                            @field(namespace, s.name) = ns.getBool(s.name) orelse brk: {
                                if (s.defaultValue()) |dv| {
                                    break :brk dv;
                                } else return error.SettingMissing;
                            };
                        },
                        ?bool => {
                            @field(namespace, s.name) = ns.getBool(s.name);
                        },
                        []const u8 => {
                            @field(namespace, s.name) = ns.get(s.name) orelse return error.SettingMissing;
                        },
                        ?[]const u8 => {
                            @field(namespace, s.name) = ns.get(s.name);
                        },
                        else => @compileError("not implemented"),
                    }
                }
                return namespace;
            }
        };

        pub const Self = @This();

        fn makeBase(self: IniData) !Base {
            if (Base == void) return {};
            var base: Base = undefined;
            inline for (@typeInfo(Base).@"struct".fields) |f| {
                if (f.type == []const u8) continue; // Root variable not yet supported
                switch (@typeInfo(f.type)) {
                    .@"struct" => {
                        @field(base, f.name) = try self.buildStruct(f.type, f.name) orelse return error.NamespaceMissing;
                    },
                    .optional => {
                        @field(base, f.name) = self.buildStruct(@typeInfo(f.type).optional.child, f.name) catch null;
                    },
                    else => @compileError("not implemented"),
                }
            }

            return base;
        }

        pub fn raze(self: Self, a: Allocator) void {
            for (self.ctx.ns) |ns| {
                ns.raze(a);
            }
            a.free(self.ctx.ns);
            if (self.ctx.owned) |owned| {
                a.free(owned);
            }
        }

        /// `data` must outlive returned object
        pub fn init(a: Allocator, data: []const u8) !Self {
            var itr = splitScalar(u8, data, '\n');

            var list: std.ArrayList(Namespace) = .{};
            errdefer {
                for (list.items) |itm| itm.raze(a);
                list.deinit(a);
            }

            while (itr.next()) |wide| {
                const line = trim(u8, wide, " \n\t");
                if (line.len == 0) continue;

                if (line[0] == '[' and line[line.len - 1] == ']') {
                    try list.append(a, try Namespace.init(a, line, &itr));
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
            var w: Writer.Allocating = .init(a);
            var r_b: [2048]u8 = undefined;
            var reader = file.reader(io, &r_b);
            _ = try reader.interface.stream(&w.writer, .limited(0x8000));

            const data = try w.toOwnedSlice();
            var self: Self = try init(a, data);
            self.ctx.owned = data;
            return self;
        }
    };
}

test "default" {
    const a = std.testing.allocator;

    const expected = Config(void){
        .config = {},
        .ctx = .{
            .ns = @constCast(&[1]Namespace{
                Namespace{
                    .name = @as([]u8, @constCast("one")),
                    .settings = @constCast(&[1]Setting{
                        .{
                            .name = "left",
                            .val = "right",
                        },
                    }),
                    .block = @constCast("left = right"),
                },
            }),
            .data = @constCast("[one]\nleft = right"),
            .owned = null,
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

    const expected = Config(void){
        .config = {},
        .ctx = .{
            .ns = @constCast(&[1]Namespace{
                Namespace{
                    .name = @as([]u8, @constCast("open")),
                    .settings = @constCast(
                        &[2]Setting{
                            .{ .name = "left", .val = "right" },
                            .{ .name = "this", .val = "works" },
                        },
                    ),
                    .block = @constCast(vut[7..]),
                },
            }),
            .data = @constCast(vut),
            .owned = null,
        },
    };

    const vtest = try Config(void).init(a, vut);
    defer vtest.raze(a);

    try std.testing.expectEqualDeep(expected, vtest);
}

const std = @import("std");
const eql = std.mem.eql;
const trim = std.mem.trim;
const count = std.mem.count;
const startsWith = std.mem.startsWith;
const lowerString = std.ascii.lowerString;
const splitScalar = std.mem.splitScalar;
const indexOfScalar = std.mem.indexOfScalar;
const ScalarIter = std.mem.SplitIterator(u8, .scalar);

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
