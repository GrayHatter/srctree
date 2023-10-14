const std = @import("std");
const bldtmpls = @import("templates");
const Allocator = std.mem.Allocator;

const MAX_BYTES = 2 <<| 15;
const TEMPLATE_PATH = "templates/";

pub const Template = struct {
    path: []const u8,
    /// expected to be a pointer to path.
    name: []const u8,
    blob: []const u8,
    parent: ?*const Template = null,
    vars: ?[]struct {
        name: []const u8,
        blob: []const u8,
    } = null,

    pub fn format(self: *Template, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        try out.print("Template not implemented ({s])\n", .{self.name});
    }
};

var _alloc: Allocator = undefined;

fn tail(path: []const u8) []const u8 {
    if (std.mem.indexOf(u8, path, "/") == null) return path[0..0];
    var itr = std.mem.splitBackwards(u8, path, "/");
    return itr.first();
}

pub var builtin: [bldtmpls.names.len]Template = blk: {
    var t: [bldtmpls.names.len]Template = undefined;
    inline for (bldtmpls.names, &t) |file, *dst| {
        dst.*.path = file;
        dst.*.name = tail(file);
        dst.*.blob = @embedFile(file);
    }
    break :blk t;
};

pub var dynamic: []Template = undefined;

fn load(a: Allocator) !void {
    var cwd = std.fs.cwd();
    var idir = cwd.openIterableDir(TEMPLATE_PATH, .{}) catch |err| {
        std.debug.print("template build error {}\n", .{err});
        return;
    };
    var itr = idir.iterate();
    var list = std.ArrayList(Template).init(a);
    while (try itr.next()) |file| {
        if (file.kind != .file) continue;
        const name = try std.mem.join(a, "/", &[2][]const u8{
            TEMPLATE_PATH,
            file.name,
        });
        defer a.free(name);
        const path = try a.dupe(u8, file.name);
        try list.append(.{
            .path = path,
            .name = tail(path),
            .blob = try cwd.readFileAlloc(a, name, MAX_BYTES),
        });
    }
    dynamic = try list.toOwnedSlice();
}

pub fn init(a: Allocator) void {
    _alloc = a;
    load(a) catch unreachable;
}

pub fn raze() void {
    for (dynamic) |t| {
        _alloc.free(t.path);
        _alloc.free(t.blob);
    }
    _alloc.free(dynamic);
}

pub fn find(comptime name: []const u8) Template {
    for (builtin) |bi| {
        if (std.mem.eql(u8, bi.name, name)) {
            return bi;
        }
    }
    unreachable;
}

test "build.zig included templates" {
    //try std.testing.expectEqual(3, bldtmpls.names.len);
    try std.testing.expectEqualStrings("templates/4XX.html", bldtmpls.names[0]);
    try std.testing.expectEqualStrings("templates/5XX.html", bldtmpls.names[1]);
    try std.testing.expectEqualStrings("templates/index.html", bldtmpls.names[2]);
}

test "load templates" {
    const a = std.testing.allocator;
    init(a);
    defer raze();

    //try std.testing.expectEqual(3, builtin.len);
    for (builtin) |bi| {
        if (std.mem.eql(u8, bi.path, "templates/index.html")) {
            try std.testing.expectEqualStrings("index.html", bi.name);
            try std.testing.expectEqualStrings("<!DOCTYPE html>", bi.blob[0..15]);
            break;
        }
    } else {
        return error.TemplateNotFound;
    }
}
