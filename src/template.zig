const std = @import("std");
//const build_templates = @import("templates");
const Allocator = std.mem.Allocator;

const MAX_BYTES = 2 <<| 15;
const TEMPLATE_PATH = "templates/";

const template_files = [3][]const u8{
    "index.html",
    "4XX.html",
    "5XX.html",
};

pub const Template = struct {
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

pub var builtin: [template_files.len]Template = blk: {
    var buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var a = fba.allocator();
    var t: [template_files.len]Template = undefined;
    inline for (template_files, &t) |file, *dst| {
        const filename = std.mem.join(a, "", &[2][]const u8{
            TEMPLATE_PATH,
            file,
        }) catch "ERROR GENERATING BLOB";
        dst.*.name = file;
        dst.*.blob = @embedFile(filename);
    }
    break :blk t;
};

pub var dynamic: []Template = undefined;

fn load(a: Allocator) !void {
    var cwd = std.fs.cwd();
    var idir = cwd.openIterableDir(TEMPLATE_PATH, .{}) catch |err| {
        std.debug.print("template build error {}", .{err});
        return err;
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
        try list.append(.{
            .name = try a.dupe(u8, file.name),
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
        _alloc.free(t.name);
        _alloc.free(t.blob);
    }
    _alloc.free(dynamic);
}

test "load templates" {
    const a = std.testing.allocator;
    init(a);
    defer raze();
    try std.testing.expectEqualStrings("HTTP/1.1 200 Found", builtin[0].blob[0..18]);
}
