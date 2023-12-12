const std = @import("std");
const bldtmpls = @import("templates");

const Allocator = std.mem.Allocator;

const HTML = @import("html.zig");
const Context = @import("context.zig");

const MAX_BYTES = 2 <<| 15;
const TEMPLATE_PATH = "templates/";

fn validChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z' => true,
        '-', '_', '.', ':' => true,
        else => false,
    };
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
            return error.OutOfMemory;
        }
    }

    /// caller owns of the returned slice, freeing the data before the final use is undefined
    pub fn addElements(self: *Template, a: Allocator, name: []const u8, els: []const HTML.Element) ![]const u8 {
        return self.addElementsFmt(a, "{}", name, els);
    }

    /// caller owns of the returned slice, freeing the data before the final use is undefined
    pub fn addElementsFmt(
        self: *Template,
        a: Allocator,
        comptime fmt: []const u8,
        name: []const u8,
        els: []const HTML.Element,
    ) ![]const u8 {
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

    /// Deprecated, use addString
    pub fn addVar(self: *Template, name: []const u8, value: []const u8) !void {
        return self.addString(name, value);
    }

    pub fn addString(self: *Template, name: []const u8, value: []const u8) !void {
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

    pub fn buildFor(self: *Template, a: Allocator, ctx: *const Context) ![]u8 {
        const loggedin = if (ctx.request.auth.valid()) "<a href=\"#\">Logged In</a>" else "Public";
        try self.addVar("header.auth", loggedin);
        if (ctx.request.auth.user(a)) |usr| {
            try self.addVar("current_username", usr.username);
        } else |_| {}
        return try self.build(a);
    }

    fn validDirective(str: []const u8) ?Directive {
        if (str.len == 0) return null;
        // parse name
        // parse directive
        // parse alternate
        var width: usize = 0;
        while (width < str.len and validChar(str[width])) {
            width += 1;
        }

        if (std.mem.startsWith(u8, str[width..], " ORELSE ")) {
            return Directive{
                .str = str[0..width],
                .otherwise = .{ .str = str[width + 8 ..] },
            };
        } else if (std.mem.eql(u8, str[width..], " ORNULL")) {
            return Directive{
                .str = str[0..width],
                .otherwise = .{ .del = {} },
            };
        } else {
            for (str[width..]) |s| if (s != ' ') return null;
            return Directive{
                .str = str,
            };
        }
    }

    pub fn format(self: Template, comptime fmts: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        var vars = self.vars orelse return try out.writeAll(self.blob);

        var blob = self.blob;
        while (blob.len > 0) {
            if (std.mem.indexOf(u8, blob, "<!-- ")) |offset| {
                try out.writeAll(blob[0..offset]);
                blob = blob[offset..];
                //var i: usize = 5;
                //var c = blob[i];
                if (std.mem.indexOf(u8, blob, " -->")) |end| {
                    if (validDirective(blob[5..end])) |dr| {
                        const var_name = dr.str;
                        // printing
                        if (var_name[0] == '_') {
                            blob = blob[end + 4 ..];
                            for (0..builtin.len) |subtemp_i| {
                                if (std.mem.eql(u8, builtin[subtemp_i].name, var_name)) {
                                    var subtmp = builtin[subtemp_i];
                                    subtmp.vars = self.vars;
                                    try subtmp.format(fmts, .{}, out);
                                    break;
                                }
                            }
                            continue;
                        }
                        for (vars) |v| {
                            if (std.mem.eql(u8, var_name, v.name)) {
                                try out.writeAll(v.blob);
                                blob = blob[end + 4 ..];
                                break;
                            }
                        } else {
                            switch (dr.otherwise) {
                                .str => |str| {
                                    try out.writeAll(str);
                                    blob = blob[end + 4 ..];
                                },
                                .ign => {
                                    try out.writeAll(blob[0 .. end + 4]);
                                    blob = blob[end + 4 ..];
                                },
                                .del => {
                                    blob = blob[end + 4 ..];
                                },
                                else => unreachable,
                            }
                        }
                    } else {
                        try out.writeAll(blob[0 .. end + 4]);
                        blob = blob[end + 4 ..];
                    }
                    continue;
                }
            }
            return try out.writeAll(blob);
        }
    }
};

pub const Directive = struct {
    str: []const u8,
    otherwise: union(enum) {
        ign: void,
        del: void,
        str: []const u8,
        template: []const u8,
    } = .{ .ign = {} },
};

fn tail(path: []const u8) []const u8 {
    if (std.mem.indexOf(u8, path, "/")) |i| {
        return path[i + 1 ..];
    }
    return path[0..0];
}

pub const builtin: [bldtmpls.names.len]Template = blk: {
    @setEvalBranchQuota(5000);
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
        std.debug.print("Unable to build dynamic templates ({})\n", .{err});
        return;
    };
    defer idir.close();
    var itr = idir.iterate();
    var list = std.ArrayList(Template).init(a);
    errdefer list.clearAndFree();
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
    load(a) catch unreachable;
}

pub fn raze(a: Allocator) void {
    for (dynamic) |t| {
        a.free(t.path);
        a.free(t.blob);
    }
    a.free(dynamic);
}

pub fn findWhenever(name: []const u8) Template {
    for (dynamic) |d| {
        if (std.mem.eql(u8, d.name, name)) {
            return d;
        }
    }
    unreachable;
}

pub fn find(comptime name: []const u8) Template {
    inline for (builtin) |bi| {
        if (comptime std.mem.eql(u8, bi.name, name)) {
            return bi;
        }
    }
    @compileError("template " ++ name ++ " not found!");
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
    defer raze(a);

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
