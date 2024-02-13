const std = @import("std");
const bldtmpls = @import("templates");

const Allocator = std.mem.Allocator;

const HTML = @import("html.zig");

const MAX_BYTES = 2 <<| 15;
const TEMPLATE_PATH = "templates/";

fn validChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z' => true,
        '-', '_', '.', ':' => true,
        else => false,
    };
}

pub const Context = struct {
    pub const HashMap = std.StringHashMap([]const u8);
    pub const HashMapSlice = std.StringHashMap([]const Context);
    ctx: HashMap,
    ctx_slice: HashMapSlice,

    pub fn init(a: Allocator) Context {
        return Context{
            .ctx = HashMap.init(a),
            .ctx_slice = HashMapSlice.init(a),
        };
    }

    pub fn raze(self: *Context) void {
        self.ctx.deinit();
        self.ctx_slice.deinit();
    }

    pub fn put(self: *Context, name: []const u8, value: []const u8) !void {
        try self.ctx.put(name, value);
    }

    pub fn get(self: Context, name: []const u8) ?[]const u8 {
        return self.ctx.get(name);
    }

    /// Memory of block is managed by the caller. Calling raze will not free the
    /// memory from within.
    pub fn putBlock(self: *Context, name: []const u8, block: []const Context) !void {
        try self.ctx_slice.put(name, block);
    }

    pub fn getBlock(self: Context, name: []const u8) ?[]const Context {
        return self.ctx_slice.get(name);
    }
};

pub const Template = struct {
    alloc: ?Allocator = null,
    ctx: ?Context = null,
    path: []const u8,
    /// expected to be a pointer to path.
    name: []const u8,
    blob: []const u8,
    parent: ?*const Template = null,

    /// This init takes a 'self' to support creation at comptime
    pub fn init(self: *Template, a: Allocator) void {
        self.alloc = a;
        self.ctx = Context.init(a);
    }

    pub fn raze(self: *Template) void {
        self.ctx.raze();
    }

    /// caller owns of the returned slice, freeing the data before the final use is undefined
    pub fn addElements(self: *Template, a: Allocator, name: []const u8, els: []const HTML.Element) !void {
        return self.addElementsFmt(a, "{}", name, els);
    }

    /// caller owns of the returned slice, freeing the data before the final use is undefined
    pub fn addElementsFmt(
        self: *Template,
        a: Allocator,
        comptime fmt: []const u8,
        name: []const u8,
        els: []const HTML.Element,
    ) !void {
        var list = try a.alloc([]u8, els.len);
        defer a.free(list);
        for (list, els) |*l, e| {
            l.* = try std.fmt.allocPrint(a, fmt, .{e});
        }
        defer {
            for (list) |l| a.free(l);
        }
        var value = try std.mem.join(a, "", list);

        try self.ctx.?.put(name, value);
    }

    /// Deprecated, use addString
    pub fn addVar(self: *Template, name: []const u8, value: []const u8) !void {
        return self.addString(name, value);
    }

    pub fn addString(self: *Template, name: []const u8, value: []const u8) !void {
        try self.ctx.?.put(name, value);
    }

    pub fn build(self: *Template, ext_a: ?Allocator) ![]u8 {
        var a = ext_a orelse self.alloc orelse unreachable; // return error.AllocatorInvalid;
        return std.fmt.allocPrint(a, "{}", .{self});
    }

    pub fn buildFor(self: *Template, a: Allocator, ctx: Context) ![]u8 {
        var template = self.*;
        if (template.ctx) |_| {
            var itr = ctx.ctx.iterator();
            while (itr.next()) |n| {
                try template.ctx.?.put(n.key_ptr.*, n.value_ptr.*);
            }
        } else {
            template.ctx = ctx;
        }
        return try template.build(a);
    }

    fn templateSearch() bool {
        return false;
    }

    fn directiveVerb(noun: []const u8, verb: []const u8, blob: []const u8) ?Directive.Kind {
        if (std.mem.eql(u8, noun, "FOREACH")) {
            const start = 3 + (std.mem.indexOf(u8, blob, "-->") orelse return null);
            const end = std.mem.indexOf(u8, blob, "<!-- END !-->") orelse return null;
            var width: usize = 1;
            while (width < verb.len and validChar(verb[width])) {
                width += 1;
            }
            return .{ .verb = .{
                .vari = verb[1..width],
                .blob = blob[start..end],
            } };
        }
        return null;
    }

    fn validDirective(str: []const u8) ?Directive {
        if (str.len == 0) return null;
        const end = std.mem.indexOf(u8, str, " -->") orelse return null;

        var width: usize = 0;
        while (width < str.len and validChar(str[width])) {
            width += 1;
        }

        const vari = str[0..width];
        const verb = str[width..];

        if (vari[0] == '_') {
            for (0..builtin.len) |subtemp_i| {
                if (std.mem.eql(u8, builtin[subtemp_i].name, vari)) {
                    return Directive{
                        .end = end,
                        .kind = .{ .noun = .{
                            .vari = vari,
                            .otherwise = .{ .template = builtin[subtemp_i] },
                        } },
                    };
                }
            }
            return Directive{
                .end = end,
                .kind = .{ .noun = .{
                    .vari = vari,
                } },
            };
        } else if (directiveVerb(vari, verb, str)) |kind| {
            return Directive{
                .end = std.mem.indexOf(u8, str, "!-->") orelse return null,
                .kind = kind,
            };
        } else if (std.mem.startsWith(u8, verb, " ORELSE ")) {
            return Directive{
                .end = end,
                .kind = .{
                    .noun = .{
                        .vari = str[0..width],
                        .otherwise = .{ .str = str[width + 8 .. str.len - 4] },
                    },
                },
            };
        } else if (std.mem.startsWith(u8, verb, " ORNULL -->")) {
            return Directive{
                .end = end,
                .kind = .{ .noun = .{
                    .vari = str[0..width],
                    .otherwise = .{ .del = {} },
                } },
            };
        } else {
            return Directive{
                .end = end,
                .kind = .{ .noun = .{
                    .vari = vari,
                } },
            };
        }
    }

    pub fn format(self: Template, comptime fmts: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        var ctx = self.ctx orelse unreachable; // return error.TemplateContextMissing;
        var blob = self.blob;
        while (blob.len > 0) {
            if (std.mem.indexOf(u8, blob, "<!-- ")) |offset| {
                try out.writeAll(blob[0..offset]);
                blob = blob[offset..];
                //var i: usize = 5;
                //var c = blob[i];
                if (validDirective(blob[5..])) |drct| {
                    const end = drct.end + 5;
                    switch (drct.kind) {
                        .noun => |noun| {
                            const var_name = noun.vari;
                            // printing
                            if (ctx.get(var_name)) |v_blob| {
                                try out.writeAll(v_blob);
                                blob = blob[end + 4 ..];
                            } else {
                                switch (noun.otherwise) {
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
                                    .template => |subt| {
                                        blob = blob[end + 4 ..];
                                        var subtmpl = subt;
                                        subtmpl.ctx = self.ctx;
                                        try subtmpl.format(fmts, .{}, out);
                                    },
                                }
                            }
                        },
                        .verb => |verb| {
                            if (ctx.getBlock(verb.vari)) |block| {
                                for (block) |s| {
                                    verb.loop(&s, out) catch unreachable;
                                }
                            } else {
                                std.debug.print("block missing [{s}]\n", .{verb.vari});
                                try out.writeAll(blob[0 .. end + 4]);
                            }
                            blob = blob[end + 4 ..];
                        },
                    }
                } else {
                    return try out.writeAll(blob);
                }

                continue;
            }
            return try out.writeAll(blob);
        }
    }
};

pub const Directive = struct {
    pub const Kind = union(enum) {
        pub const Noun = struct {
            vari: []const u8,
            otherwise: union(enum) {
                ign: void,
                del: void,
                str: []const u8,
                template: Template,
            } = .{ .ign = {} },
        };

        pub const Verb = struct {
            vari: []const u8,
            blob: []const u8,

            pub fn loop(self: Verb, block: *const Context, out: anytype) anyerror!void {
                var t = Template{
                    .name = self.vari,
                    .path = "/dev/null",
                    // would be nice not to have to do a mov here
                    .ctx = block.*,
                    .blob = self.blob,
                };
                try t.format("", .{}, out);
            }
        };

        noun: Noun,
        verb: Verb,
    };

    kind: Kind,
    end: usize,
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

test "directive nothing" {
    var a = std.testing.allocator;
    var t = Template{
        .alloc = null,
        .path = "/dev/null",
        .name = "test",
        .blob = "<!-- nothing -->",
    };

    const page = try t.buildFor(a, Context.init(a));
    defer a.free(page);
    try std.testing.expectEqualStrings("<!-- nothing -->", page);
}

test "directive ORELSE" {
    var a = std.testing.allocator;
    var t = Template{
        .alloc = null,
        .path = "/dev/null",
        .name = "test",
        .blob = "<!-- this ORELSE string until end -->",
    };

    const page = try t.buildFor(a, Context.init(a));
    defer a.free(page);
    try std.testing.expectEqualStrings("string until end", page);
}

test "directive ORNULL" {
    var a = std.testing.allocator;
    var t = Template{
        .alloc = null,
        .path = "/dev/null",
        .name = "test",
        // Invalid because 'string until end' is known to be unreachable
        .blob = "<!-- this ORNULL string until end -->",
    };

    const page = try t.buildFor(a, Context.init(a));
    defer a.free(page);
    try std.testing.expectEqualStrings("<!-- this ORNULL string until end -->", page);

    t = Template{
        .alloc = null,
        .path = "/dev/null",
        .name = "test",
        .blob = "<!-- this ORNULL -->",
    };

    const nullpage = try t.buildFor(a, Context.init(a));
    defer a.free(nullpage);
    try std.testing.expectEqualStrings("", nullpage);
}

test "directive FOR" {}

test "directive FOREACH" {
    var a = std.testing.allocator;

    const blob =
        \\<!-- FOREACH name -->
        \\<div><!-- loop --></div>
        \\<!-- END !-->
    ;

    const expected: []const u8 =
        \\
        \\<div>not that</div>
        \\
    ;

    const dbl_expected: []const u8 =
        \\
        \\<div>first</div>
        \\
        \\<div>second</div>
        \\
    ;

    var t = Template{
        .alloc = null,
        .path = "/dev/null",
        .name = "test",
        .blob = blob,
    };

    var ctx = Context.init(a);
    var blocks: [1]Context = [1]Context{
        Context.init(a),
    };
    try blocks[0].put("loop", "not that");
    try ctx.putBlock("name", &blocks);
    defer ctx.ctx_slice.deinit();

    const page = try t.buildFor(a, ctx);
    defer a.free(page);
    try std.testing.expectEqualStrings(expected, page);
    blocks[0].raze();

    // many
    var many_blocks: [2]Context = [_]Context{
        Context.init(a),
        Context.init(a),
    };
    // what... 2 is many

    try many_blocks[0].put("loop", "first");
    try many_blocks[1].put("loop", "second");

    try ctx.putBlock("name", &many_blocks);

    const dbl_page = try t.buildFor(a, ctx);
    defer a.free(dbl_page);
    try std.testing.expectEqualStrings(dbl_expected, dbl_page);

    many_blocks[0].raze();
    many_blocks[1].raze();
}
