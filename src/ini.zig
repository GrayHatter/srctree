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

    pub fn raze(self: Namespace, a: Allocator) void {
        a.free(self.name);
        for (self.settings) |set| {
            a.free(set.name);
            a.free(set.val);
        }
        a.free(self.settings);
    }
};

pub const Config = struct {
    ns: []Namespace,

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

    pub fn raze(self: Config, a: Allocator) void {
        for (self.ns) |ns| {
            ns.raze(a);
        }
        a.free(self.ns);
    }
};

fn namespace(a: Allocator, name: []const u8, itr: *std.mem.SplitIterator(u8, .sequence)) !Namespace {
    var list = std.ArrayList(Setting).init(a);

    while (itr.peek()) |peek| {
        var line = std.mem.trim(u8, peek, " \n\t");
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

pub fn init(a: Allocator, file: std.fs.File) !Config {
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

    return Config{
        .ns = try list.toOwnedSlice(),
    };
}

var _default: ?Config = null;

pub fn default(a: Allocator) !Config {
    if (_default) |d| return d;

    var cwd = std.fs.cwd();
    var file = try cwd.openFile("./config.ini", .{});
    defer file.close();

    _default = try init(a, file);
    return _default.?;
}
