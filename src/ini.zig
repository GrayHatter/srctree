const std = @import("std");

const Allocator = std.mem.Allocator;

const Setting = struct {
    name: []u8,
    val: []u8,
};

pub const Namespace = struct {
    name: []u8,
    settings: []Setting,

    pub fn get(self: Namespace, name: []const u8) ?[]const u8 {
        for (self.settings) |st| {
            if (std.mem.eql(u8, name, st.name)) {
                return st.val;
            }
        }
        return null;
    }
};

pub const Config = struct {
    ns: []Namespace,

    pub fn get(self: Config, name: []const u8) ?*const Namespace {
        for (self.ns) |ns| {
            if (std.mem.eql(u8, name, ns.name)) {
                return &ns;
            }
        }
        return null;
    }
};

fn pair(a: Allocator, str: []const u8) !Setting {
    if (std.mem.indexOf(u8, str, "=")) |i| {
        return .{
            .name = try a.dupe(u8, std.mem.trim(u8, str[0..i], " \n\t")),
            .val = try a.dupe(u8, std.mem.trim(u8, str[i + 1 ..], " \n\t")),
        };
    }
    unreachable;
}

fn namespace(a: Allocator, name: []const u8, itr: *std.mem.SplitIterator(u8, .sequence)) !Namespace {
    var list = std.ArrayList(Setting).init(a);

    while (itr.peek()) |peek| {
        if (std.mem.count(u8, peek, "=") == 0) {
            _ = itr.next();
            continue;
        }
        var line = std.mem.trim(u8, peek, " \n\t");
        if (line[0] == '[') break;

        try list.append(try pair(a, peek));
        _ = itr.next();
    }

    return .{
        .name = try a.dupe(u8, name[1 .. name.len - 1]),
        .settings = try list.toOwnedSlice(),
    };
}

pub fn getConfig(a: Allocator, file: std.fs.File) !Config {
    var data = try file.readToEndAlloc(a, 1 <<| 18);
    defer a.free(data);
    var itr = std.mem.split(u8, data, "\n");

    var list = std.ArrayList(Namespace).init(a);

    while (itr.next()) |wide| {
        var line = std.mem.trim(u8, wide, " \n\t");
        if (line.len == 0) continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            try list.append(try namespace(a, line, &itr));
        }
    }

    return .{
        .ns = try list.toOwnedSlice(),
    };
}
