const std = @import("std");
const bldtmpls = @import("templates");

const Allocator = std.mem.Allocator;

const HTML = @import("html.zig");
const Response = @import("response.zig");

const MAX_BYTES = 2 <<| 15;
const TEMPLATE_PATH = "templates/";

fn validChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or c == '-' or c == '_' or (c >= 'A' and c <= 'Z') or c == '.' or c == ':';
}

pub const Template = struct {
    alloc: ?Allocator = null,
    path: []const u8,
    /// expected to be a pointer to path.
    name: []const u8,
    blob: []const u8,
    parent: ?*const Template = null,
    vars: ?[]Var = null,
    const Var = struct {
        name: []const u8,
        blob: []const u8,
    };

    pub fn init(self: *Template, a: Allocator) void {
        self.alloc = a;
    }

    fn expandVars(self: *Template) !void {
        if (self.alloc) |a| {
            if (self.vars) |vars| {
                if (!a.resize(vars, vars.len + 1)) {
                    self.vars = try a.realloc(vars, vars.len + 1);
                } else {
                    self.vars.?.len += 1;
                }
            } else {
                self.vars = try a.alloc(Var, 1);
            }
        } else {
            return error.UnableToAlloc;
        }
    }

    pub fn addElements(self: *Template, a: Allocator, name: []const u8, els: []const HTML.Element) ![]const u8 {
        return self.addElementsFmt(a, "{}", name, els);
    }

    // caller is responsable to free the returned slice *AFTER* the final use
    pub fn addElementsFmt(self: *Template, a: Allocator, comptime fmt: []const u8, name: []const u8, els: []const HTML.Element) ![]const u8 {
        try self.expandVars();
        var list = try a.alloc([]u8, els.len);
        defer a.free(list);
        for (list, els) |*l, e| {
            l.* = try std.fmt.allocPrint(a, fmt, .{e});
        }
        defer {
            for (list) |l| a.free(l);
        }
        var value = try std.mem.join(a, "", list);

        if (self.vars) |vars| {
            vars[vars.len - 1] = .{
                .name = name,
                .blob = value,
            };
        }
        return value;
    }

    pub fn addVar(self: *Template, name: []const u8, value: []const u8) !void {
        try self.expandVars();
        if (self.vars) |vars| {
            vars[vars.len - 1] = .{
                .name = name,
                .blob = value,
            };
        }
    }

    pub fn build(self: *Template, ext_a: ?Allocator) ![]u8 {
        var a = ext_a orelse self.alloc orelse return error.AllocatorInvalid;
        return std.fmt.allocPrint(a, "{}", .{self});
    }

    pub fn buildFor(self: *Template, a: ?Allocator, r: *const Response) ![]u8 {
        const loggedin = if (r.request.auth.valid()) "<a href=\"#\">Logged In</a>" else "Public";
        try self.addVar("header.auth", loggedin);
        return try self.build(a);
    }

    pub fn format(self: Template, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        if (self.vars) |vars| {
            var start: usize = 0;
            while (start < self.blob.len) {
                if (std.mem.indexOf(u8, self.blob[start..], "<!-- ")) |offset| {
                    try out.writeAll(self.blob[start .. start + offset]);
                    start += offset;
                    var i: usize = 5;
                    var c = self.blob[start + i];
                    while (validChar(c)) {
                        i += 1;
                        c = self.blob[start + i];
                    }
                    if (!std.mem.eql(u8, " -->", self.blob[start + i .. start + i + 4])) {
                        try out.writeAll(self.blob[start .. start + i]);
                        start += i;
                        continue;
                    }
                    const var_name = self.blob[start + 5 .. start + i];
                    if (var_name[0] == '_') {
                        start += i + 4;
                        for (0..builtin.len) |subtemp_i| {
                            if (std.mem.eql(u8, builtin[subtemp_i].name, var_name)) {
                                var subtmp = builtin[subtemp_i];
                                subtmp.vars = self.vars;
                                try format(subtmp, "", .{}, out);
                            }
                        }
                        continue;
                    }
                    for (vars) |v| {
                        if (std.mem.eql(u8, var_name, v.name)) {
                            try out.writeAll(v.blob);
                            start += i + 4;
                            break;
                        }
                    } else {
                        try out.writeAll(self.blob[start .. start + i + 4]);
                        start += i + 4;
                    }
                } else {
                    try out.writeAll(self.blob[start..]);
                    break;
                }
            }
        } else {
            try out.writeAll(self.blob);
        }
    }
};

var _alloc: Allocator = undefined;

fn tail(path: []const u8) []const u8 {
    if (std.mem.indexOf(u8, path, "/") == null) return path[0..0];
    return path[std.mem.lastIndexOf(u8, path, "/").? + 1 ..];
}

pub const builtin: [bldtmpls.names.len]Template = blk: {
    var t: [bldtmpls.names.len]Template = undefined;
    inline for (bldtmpls.names, &t) |file, *dst| {
        dst.* = Template{
            .alloc = null,
            .path = file,
            .name = tail(file),
            .blob = @embedFile(file),
        };
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
    inline for (builtin) |bi| {
        if (std.mem.eql(u8, bi.name, name)) {
            return bi;
        }
    }
    unreachable;
}

test "build.zig included templates" {
    //try std.testing.expectEqual(3, bldtmpls.names.len);
    const names = [_][]const u8{
        "templates/4XX.html",
        "templates/5XX.html",
        "templates/index.html",
        "templates/code.html",
    };

    names: for (names) |name| {
        for (bldtmpls.names) |bld| {
            if (std.mem.eql(u8, name, bld)) continue :names;
        } else return error.TemplateMissing;
    }
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

test "init" {
    var a = std.testing.allocator;

    var tmpl = find("user_commits.html");
    tmpl.init(a);
}
