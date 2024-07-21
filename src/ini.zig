const std = @import("std");

const Allocator = std.mem.Allocator;

const Setting = struct {
    name: []const u8,
    val: []const u8,

    fn pair(a: Allocator, str: []const u8) !Setting {
        if (std.mem.indexOf(u8, str, "=")) |i| {
            return .{
                .name = try a.dupe(u8, std.mem.trim(u8, str[0..i], " \n\t")),
                .val = try a.dupe(u8, std.mem.trim(u8, str[i + 1 ..], " \n\t")),
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

    pub fn init(
        a: Allocator,
        name: []const u8,
        itr: *std.mem.SplitIterator(u8, .sequence),
    ) !Namespace {
        var list = std.ArrayList(Setting).init(a);

        while (itr.peek()) |peek| {
            const line = std.mem.trim(u8, peek, " \n\t");
            if (line.len == 0) {
                _ = itr.next();
                continue;
            }
            if (line[0] == '[') break;
            if (std.mem.count(u8, line, "=") == 0) {
                _ = itr.next();
                continue;
            }

            try list.append(try Setting.pair(a, line));
            _ = itr.next();
        }

        return .{
            .name = try a.dupe(u8, name[1 .. name.len - 1]),
            .settings = try list.toOwnedSlice(),
        };
    }

    pub fn get(self: Namespace, name: []const u8) ?[]const u8 {
        for (self.settings) |st| {
            if (std.mem.eql(u8, name, st.name)) {
                return st.val;
            }
        }
        return null;
    }

    pub fn raze(self: Namespace, a: Allocator) void {
        a.free(self.name);
        for (self.settings) |set| {
            set.raze(a);
        }
        a.free(self.settings);
    }
};

pub const Config = struct {
    alloc: Allocator,
    ns: []Namespace,
    data: []u8,

    pub fn empty() Config {
        return .{
            .ns = &[0]Namespace{},
        };
    }

    pub fn filter(self: Config, prefix: []const u8, index: usize) ?Namespace {
        var remaining = index;
        for (self.ns) |ns| {
            if (std.mem.startsWith(u8, ns.name, prefix)) {
                if (remaining == 0) return ns;
                remaining -= 1;
            }
        } else return null;
    }

    pub fn get(self: Config, name: []const u8) ?Namespace {
        for (self.ns) |ns| {
            if (std.mem.eql(u8, ns.name, name)) {
                return ns;
            }
        }
        return null;
    }

    pub fn raze(self: Config) void {
        for (self.ns) |ns| {
            ns.raze(self.alloc);
        }
        self.alloc.free(self.ns);
        self.alloc.free(self.data);
    }
};

pub fn initDupe(a: Allocator, ini: []const u8) !Config {
    const owned = try a.dupe(u8, ini);
    return try init(a, owned);
}

/// `ini` becomes owned by returned Config, use initDupe otherwise
pub fn init(a: Allocator, ini: []u8) !Config {
    var itr = std.mem.split(u8, ini, "\n");

    var list = std.ArrayList(Namespace).init(a);

    while (itr.next()) |wide| {
        const line = std.mem.trim(u8, wide, " \n\t");
        if (line.len == 0) continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            try list.append(try Namespace.init(a, line, &itr));
        }
    }

    return Config{
        .alloc = a,
        .ns = try list.toOwnedSlice(),
        .data = ini,
    };
}

pub fn fromFile(a: Allocator, file: std.fs.File) !Config {
    const data = try file.readToEndAlloc(a, 1 <<| 18);
    return try init(a, data);
}

test "default" {
    const a = std.testing.allocator;
    const expected = Config{
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
            },
        }),
        .data = @constCast("[one]\nleft = right"),
    };

    const vtest = try initDupe(a, "[one]\nleft = right");
    defer vtest.raze();

    try std.testing.expectEqualDeep(expected, vtest);
}
