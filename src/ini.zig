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
        var list = std.ArrayList(Setting).init(a);
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
            try list.append(pair);
            _ = itr.next();
        }

        const ns_end = itr.index orelse itr.buffer.len;
        return .{
            .name = try a.dupe(u8, name[1 .. name.len - 1]),
            .settings = try list.toOwnedSlice(),
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

pub fn Config(Base: anytype) type {
    return struct {
        pub const Self = @This();
        alloc: Allocator,
        ns: []Namespace,
        data: []const u8,
        owned: ?[]const u8,

        fn buildStruct(self: Self, T: type, name: []const u8) !?T {
            var namespace: T = undefined;
            const ns = self.get(name) orelse return null;
            inline for (@typeInfo(T).Struct.fields) |s| {
                switch (s.type) {
                    bool => {
                        @field(namespace, s.name) = ns.getBool(s.name) orelse return error.SettingMissing;
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

        pub fn config(self: Self) !Base {
            var base: Base = undefined;
            inline for (@typeInfo(Base).Struct.fields) |f| {
                if (f.type == []const u8) continue; // Root variable not yet supported
                switch (@typeInfo(f.type)) {
                    .Struct => {
                        @field(base, f.name) = try self.buildStruct(f.type, f.name) orelse return error.NamespaceMissing;
                    },
                    .Optional => {
                        @field(base, f.name) = try self.buildStruct(@typeInfo(f.type).Optional.child, f.name) orelse return error.NamespaceMissing;
                    },
                    else => @compileError("not implemented"),
                }
            }

            return base;
        }

        pub fn filter(self: Self, prefix: []const u8, index: usize) ?Namespace {
            var remaining = index;
            for (self.ns) |ns| {
                if (startsWith(u8, ns.name, prefix)) {
                    if (remaining == 0) return ns;
                    remaining -= 1;
                }
            } else return null;
        }

        pub fn get(self: Self, name: []const u8) ?Namespace {
            for (self.ns) |ns| {
                if (eql(u8, ns.name, name)) {
                    return ns;
                }
            }
            return null;
        }

        pub fn raze(self: Self) void {
            for (self.ns) |ns| {
                ns.raze(self.alloc);
            }
            self.alloc.free(self.ns);
            if (self.owned) |owned| {
                self.alloc.free(owned);
            }
        }

        pub fn initDupe(a: Allocator, ini: []const u8) !Self {
            const owned = try a.dupe(u8, ini);
            var c = try init(a, owned);
            c.owned = c.data;
            return c;
        }

        /// `data` must outlive returned Config, use initDupe otherwise
        pub fn init(a: Allocator, data: []const u8) !Self {
            var itr = splitScalar(u8, data, '\n');

            var list = std.ArrayList(Namespace).init(a);

            while (itr.next()) |wide| {
                const line = trim(u8, wide, " \n\t");
                if (line.len == 0) continue;

                if (line[0] == '[' and line[line.len - 1] == ']') {
                    try list.append(try Namespace.init(a, line, &itr));
                }
            }

            return .{
                .alloc = a,
                .ns = try list.toOwnedSlice(),
                .data = data,
                .owned = null,
            };
        }

        /// I'm not happy with this API. I think I deleted it once already... deleted
        /// twice incoming!
        pub fn initOwned(a: Allocator, data: []u8) !Self {
            var c = try init(a, data);
            c.owned = data;
            return c;
        }

        pub fn fromFile(a: Allocator, file: std.fs.File) !Self {
            const data = try file.readToEndAlloc(a, 1 <<| 18);
            return try initOwned(a, data);
        }
    };

    //const RealBase = @Type(.{
    //    .Struct = .{
    //        .layout = .auto,
    //        .is_tuple = false,
    //        .fields = &[_]std.builtin.Type.StructField{} ++
    //            @typeInfo(Base).Struct.fields[0..] ++
    //            @typeInfo(Real).Struct.fields[0..],
    //        .decls = &[_]std.builtin.Type.Declaration{} ++
    //            @typeInfo(Base).Struct.decls ++
    //            @typeInfo(Real).Struct.decls,
    //    },
    //});
}

test "default" {
    const a = std.testing.allocator;

    const expected = Config(void){
        .alloc = a,
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
        .owned = @constCast("[one]\nleft = right"),
    };

    const vtest = try Config(void).initDupe(a, "[one]\nleft = right");
    defer vtest.raze();

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
        \\tenth = failure
        \\
    ;
    // eight & ninth are expected to have leading & trailing whitespace

    const Cfg = Config(struct {});

    const a = std.testing.allocator;
    const c = try Cfg.init(a, data);
    defer c.raze();
    const ns = c.get("test data").?;

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
        .alloc = a,
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
        .owned = @constCast(vut),
    };

    const vtest = try Config(void).initDupe(a, vut);
    defer vtest.raze();

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
