const std = @import("std");
const build_mode = @import("builtin").mode;
const compiled = @import("templates-compiled");
const isWhitespace = std.ascii.isWhitespace;
const indexOf = std.mem.indexOf;
const lastIndexOf = std.mem.lastIndexOf;

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

const DEBUG = false;

// TODO rename this to... uhhh Map maybe?
//
pub const Context = struct {
    pub const Pair = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const Data = union(enum) {
        slice: []const u8,
        block: []Context,
        reader: std.io.AnyReader,
    };

    pub const HashMap = std.StringHashMap(Data);

    ctx: HashMap,

    pub fn Builder(comptime T: type) type {
        return struct {
            from: T,

            pub const Self = @This();

            pub fn init(from: T) Self {
                return .{
                    .from = from,
                };
            }

            pub fn buildUnsanitized(self: Self, a: Allocator, ctx: *Context) !void {
                if (comptime @import("builtin").zig_version.minor >= 12) {
                    if (std.meta.hasMethod(T, "contextBuilderUnsanitized")) {
                        return self.from.contextBuilderUnsanitized(a, ctx);
                    }
                }

                inline for (std.meta.fields(T)) |field| {
                    if (field.type == []const u8) {
                        try ctx.put(field.name, @field(self.from, field.name));
                    }
                }
            }

            pub fn build(self: Self, a: Allocator, ctx: *Context) !void {
                if (comptime @import("builtin").zig_version.minor >= 12) {
                    if (std.meta.hasMethod(T, "contextBuilder")) {
                        return self.from.contextBuilder(a, ctx);
                    }
                }

                return self.buildUnsanitized(a, ctx);
            }
        };
    }

    pub fn init(a: Allocator) Context {
        return Context{
            .ctx = HashMap.init(a),
        };
    }

    pub fn initWith(a: Allocator, data: []const Pair) !Context {
        var ctx = Context.init(a);
        for (data) |d| {
            ctx.putSlice(d.name, d.value) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => unreachable,
            };
        }
        return ctx;
    }

    pub fn initBuildable(a: Allocator, buildable: anytype) !Context {
        var ctx = Context.init(a);
        const builder = buildable.builder();
        try builder.build(a, &ctx);
        return ctx;
    }

    pub fn raze(self: *Context) void {
        var itr = self.ctx.iterator();
        while (itr.next()) |*n| {
            switch (n.value_ptr.*) {
                .slice, .reader => continue,
                .block => |*block| for (block.*) |*b| b.raze(),
            }
        }
        self.ctx.deinit();
    }

    pub fn put(self: *Context, name: []const u8, value: Data) !void {
        try self.ctx.put(name, value);
    }

    pub fn get(self: Context, name: []const u8) ?Data {
        return self.ctx.get(name);
    }

    pub fn putSlice(self: *Context, name: []const u8, value: []const u8) !void {
        if (comptime build_mode == .Debug)
            if (!std.ascii.isUpper(name[0]))
                std.debug.print("Warning Template can't resolve {s}\n", .{name});
        try self.ctx.put(name, .{ .slice = value });
    }

    pub fn getSlice(self: Context, name: []const u8) ?[]const u8 {
        return switch (self.getNext(name) orelse return null) {
            .slice => |s| s,
            .block => unreachable,
            .reader => unreachable,
        };
    }

    /// Memory of block is managed by the caller. Calling raze will not free the
    /// memory from within.
    pub fn putBlock(self: *Context, name: []const u8, block: []Context) !void {
        try self.ctx.put(name, .{ .block = block });
    }

    pub fn getBlock(self: Context, name: []const u8) !?[]const Context {
        return switch (self.ctx.get(name) orelse return null) {
            // I'm sure this hack will live forever, I'm abusing With to be
            // an IF here, without actually implementing IF... sorry!
            //std.debug.print("Error: get [{s}] required Block, found slice\n", .{name});
            .slice, .reader => return error.NotABlock,
            .block => |b| b,
        };
    }

    pub fn putReader(self: *Context, name: []const u8, value: []const u8) !void {
        try self.putSlice(name, value);
    }

    pub fn getReader(self: Context, name: []const u8) ?std.io.AnyReader {
        switch (self.ctx.get(name) orelse return null) {
            .slice, .block => return error.NotAReader,
            .reader => |r| return r,
        }
        comptime unreachable;
    }
};

pub const Template = struct {
    alloc: ?Allocator = null,
    ctx: ?Context = null,
    // path: []const u8,
    name: []const u8,
    blob: []const u8,
    parent: ?*const Template = null,

    /// This init takes a 'self' to support creation at comptime
    pub fn init(self: *Template, a: Allocator) void {
        std.debug.assert(self.alloc == null);
        std.debug.assert(self.ctx == null);
        self.alloc = a;
        self.ctx = Context.init(a);
    }

    pub fn initWith(self: *Template, a: Allocator, data: []struct { name: []const u8, val: []const u8 }) !void {
        self.init(a);
        for (data) |d| {
            try self.ctx.putSlice(d.name, d.value);
        }
    }

    pub fn raze(self: *Template) void {
        self.ctx.raze();
    }

    pub fn addString(self: *Template, name: []const u8, value: []const u8) !void {
        try self.ctx.?.putSlice(name, value);
    }

    pub fn buildFor(self: *Template, a: Allocator, ctx: Context) ![]u8 {
        var template: Template = self.*;
        template.alloc = a;
        template.ctx = ctx;
        return std.fmt.allocPrint(a, "{}", .{template});
    }

    fn templateSearch() bool {
        return false;
    }

    fn calcPos(comptime keyword: []const u8, blob: []const u8, verb: []const u8) ?struct {
        start: usize,
        end: usize,
        endws: usize,
        width: usize,
    } {
        const close: *const [keyword.len + 3]u8 = "</" ++ keyword ++ ">";
        var start = 1 + (indexOf(u8, blob, ">") orelse return null);
        const end = close.len + (lastIndexOf(u8, blob, close) orelse return null);
        while (start < end and isWhitespace(blob[start])) : (start +|= 1) {}
        const endws = end - close.len;

        //while (endws > start and isWhitespace(blob[endws])) : (endws -|= 1) {}
        //endws += 1;

        var width: usize = 1;
        while (width < verb.len and validChar(verb[width])) {
            width += 1;
        }
        return .{
            .start = start,
            .width = width,
            .end = end,
            .endws = endws,
        };
    }

    fn directiveVerb(noun: []const u8, verb: []const u8, blob: []const u8) ?Directive {
        if (std.mem.eql(u8, noun, "For")) {
            const pos = calcPos("For", blob, verb) orelse return null;
            std.debug.assert(pos.width > 1);
            return .{
                .end = pos.end,
                .kind = .{
                    .verb = .{
                        .vari = verb[1..pos.width],
                        .blob = blob[pos.start..pos.endws],
                        .word = .foreach,
                    },
                },
            };
        } else if (std.mem.eql(u8, noun, "With")) {
            const pos = calcPos("With", blob, verb) orelse return null;
            std.debug.assert(pos.width > 1);
            return .{
                .end = pos.end,
                .kind = .{
                    .verb = .{
                        .vari = verb[1..pos.width],
                        .blob = blob[pos.start..pos.endws],
                        .word = .with,
                    },
                },
            };
            // pass
        }
        return null;
    }

    fn validDirective(str: []const u8) ?Directive {
        if (str.len < 2) return null;
        if (!std.ascii.isUpper(str[1]) and str[1] != '_') return null;
        const end = 1 + (std.mem.indexOf(u8, str, ">") orelse return null);

        var width: usize = 1;
        while (width < str.len and validChar(str[width])) {
            width += 1;
        }

        const vari = str[1..width];
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
            return kind;
        } else if (std.mem.startsWith(u8, verb, " ORELSE ")) {
            return Directive{
                .end = end,
                .kind = .{
                    .noun = .{
                        .vari = str[1..width],
                        .otherwise = .{ .str = str[width + 8 .. end - 1] },
                    },
                },
            };
        } else if (std.mem.startsWith(u8, verb, " ORNULL>")) {
            return Directive{
                .end = end,
                .kind = .{ .noun = .{
                    .vari = str[1..width],
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
            if (std.mem.indexOf(u8, blob, "<")) |offset| {
                try out.writeAll(blob[0..offset]);
                blob = blob[offset..];
                //var i: usize = 5;
                //var c = blob[i];
                if (validDirective(blob)) |drct| {
                    const end = drct.end;
                    switch (drct.kind) {
                        .noun => |noun| {
                            const var_name = noun.vari;
                            if (ctx.get(var_name)) |v_blob| {
                                switch (v_blob) {
                                    .slice => |s_blob| try out.writeAll(s_blob),
                                    .block => |_| unreachable,
                                    .reader => |_| unreachable,
                                }
                                blob = blob[end..];
                            } else {
                                if (DEBUG) std.debug.print("[missing var {s}]\n", .{var_name});
                                switch (noun.otherwise) {
                                    .str => |str| {
                                        try out.writeAll(str);
                                        blob = blob[end..];
                                    },
                                    .ign => {
                                        try out.writeAll(blob[0..end]);
                                        blob = blob[end..];
                                    },
                                    .del => {
                                        blob = blob[end..];
                                    },
                                    .template => |subt| {
                                        blob = blob[end..];
                                        var subtmpl = subt;
                                        subtmpl.ctx = self.ctx;
                                        try subtmpl.format(fmts, .{}, out);
                                    },
                                }
                            }
                        },
                        .verb => |verb| {
                            verb.do(&ctx, out) catch unreachable;
                            blob = blob[end..];
                        },
                    }
                } else {
                    if (std.mem.indexOfPos(u8, blob, 1, "<")) |next| {
                        try out.writeAll(blob[0..next]);
                        blob = blob[next..];
                    } else {
                        return try out.writeAll(blob);
                    }
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
            word: enum {
                foreach,
                with,
            },

            pub fn do(self: Verb, ctx: *const Context, out: anytype) anyerror!void {
                if (ctx.getBlock(self.vari) catch |err| switch (err) {
                    error.NotABlock => ctx[0..1],
                    else => return err,
                }) |block| {
                    switch (self.word) {
                        .foreach => {
                            for (block) |s| {
                                try self.foreach(&s, out);
                            }
                            return;
                        },
                        .with => {
                            std.debug.assert(block.len == 1);
                            try self.with(&block[0], out);
                            return;
                        },
                    }
                } else if (self.word == .foreach) {
                    std.debug.print("<For {s}> ctx block missing.\n", .{self.vari});
                }
            }

            pub fn foreach(self: Verb, block: *const Context, out: anytype) anyerror!void {
                var t = Template{
                    .name = self.vari,
                    //.path = "/dev/null",
                    // would be nice not to have to do a mov here
                    .ctx = block.*,
                    .blob = self.blob,
                };
                try t.format("", .{}, out);
            }

            pub fn with(self: Verb, block: *const Context, out: anytype) anyerror!void {
                var t = Template{
                    .name = self.vari,
                    //.path = "/dev/null",
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

pub const builtin: [compiled.data.len]Template = blk: {
    @setEvalBranchQuota(5000);
    var t: [compiled.data.len]Template = undefined;
    for (compiled.data, &t) |filedata, *dst| {
        dst.* = Template{
            .alloc = null,
            //.path = filedata.path,
            .name = tail(filedata.path),
            .blob = filedata.blob,
        };
    }
    break :blk t;
};

pub var dynamic: []Template = undefined;

fn loadTemplates(a: Allocator) !void {
    var cwd = std.fs.cwd();
    var idir = cwd.openDir(TEMPLATE_PATH, .{ .iterate = true }) catch |err| {
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
        const tail_ = tail(file.name);
        const name_ = try a.dupe(u8, tail_);
        try list.append(.{
            //.path = path,
            .name = name_,
            .blob = try cwd.readFileAlloc(a, name, MAX_BYTES),
        });
    }
    dynamic = try list.toOwnedSlice();
}

pub fn init(a: Allocator) void {
    loadTemplates(a) catch unreachable;
}

pub fn raze(a: Allocator) void {
    for (dynamic) |t| {
        // leaks?
        a.free(t.name);
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

pub fn load(a: Allocator, comptime name: []const u8) Template {
    var t = find(name);
    t.init(a);
    return t;
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
        for (compiled.data) |bld| {
            if (std.mem.eql(u8, name, bld.path)) continue :names;
        } else return error.TemplateMissing;
    }
}

test "load templates" {
    const a = std.testing.allocator;
    init(a);
    defer raze(a);

    //try std.testing.expectEqual(3, builtin.len);
    for (builtin) |bi| {
        if (std.mem.eql(u8, bi.name, "index.html")) {
            try std.testing.expectEqualStrings("index.html", bi.name);
            try std.testing.expectEqualStrings("<!DOCTYPE html>", bi.blob[0..15]);
            break;
        }
    } else {
        return error.TemplateNotFound;
    }
}

test "init" {
    const a = std.testing.allocator;

    var tmpl = find("user_commits.html");
    tmpl.init(a);
}

test "directive something" {
    var a = std.testing.allocator;
    var t = Template{
        .alloc = null,
        //.path = "/dev/null",
        .name = "test",
        .blob = "<Something>",
    };

    var ctx = Context.init(a);
    try ctx.putSlice("Something", "Some Text Here");
    defer ctx.raze();
    const page = try t.buildFor(a, ctx);
    defer a.free(page);
    try std.testing.expectEqualStrings("Some Text Here", page);
}

test "directive nothing" {
    var a = std.testing.allocator;
    var t = Template{
        .alloc = null,
        //.path = "/dev/null",
        .name = "test",
        .blob = "<!-- nothing -->",
    };

    const page = try t.buildFor(a, Context.init(a));
    defer a.free(page);
    try std.testing.expectEqualStrings("<!-- nothing -->", page);
}

test "directive nothing new" {
    var a = std.testing.allocator;
    var t = Template{
        .alloc = null,
        //.path = "/dev/null",
        .name = "test",
        .blob = "<Nothing>",
    };

    const page = try t.buildFor(a, Context.init(a));
    defer a.free(page);
    try std.testing.expectEqualStrings("<Nothing>", page);
}

test "directive ORELSE" {
    var a = std.testing.allocator;
    var t = Template{
        .alloc = null,
        //.path = "/dev/null",
        .name = "test",
        .blob = "<This ORELSE string until end>",
    };

    const page = try t.buildFor(a, Context.init(a));
    defer a.free(page);
    try std.testing.expectEqualStrings("string until end", page);
}

test "directive ORNULL" {
    var a = std.testing.allocator;
    var t = Template{
        .alloc = null,
        //.path = "/dev/null",
        .name = "test",
        // Invalid because 'string until end' is known to be unreachable
        .blob = "<This ORNULL string until end>",
    };

    const page = try t.buildFor(a, Context.init(a));
    defer a.free(page);
    try std.testing.expectEqualStrings("<This ORNULL string until end>", page);

    t = Template{
        .alloc = null,
        //.path = "/dev/null",
        .name = "test",
        .blob = "<This ORNULL>",
    };

    const nullpage = try t.buildFor(a, Context.init(a));
    defer a.free(nullpage);
    try std.testing.expectEqualStrings("", nullpage);
}

test "directive For 0..n" {}

test "directive For" {
    var a = std.testing.allocator;

    const blob =
        \\<div><For Loop><span><Name></span></For></div>
    ;

    const expected: []const u8 =
        \\<div><span>not that</span></div>
    ;

    const dbl_expected: []const u8 =
        \\<div><span>first</span><span>second</span></div>
    ;

    var t = Template{
        .alloc = null,
        //.path = "/dev/null",
        .name = "test",
        .blob = blob,
    };

    var ctx = Context.init(a);
    defer ctx.raze();
    var blocks: [1]Context = [1]Context{
        Context.init(a),
    };
    try blocks[0].putSlice("Name", "not that");
    // We have to raze because it will be over written
    defer blocks[0].raze();
    try ctx.putBlock("Loop", &blocks);

    const page = try t.buildFor(a, ctx);
    defer a.free(page);
    try std.testing.expectEqualStrings(expected, page);

    // many
    var many_blocks: [2]Context = [_]Context{
        Context.init(a),
        Context.init(a),
    };
    // what... 2 is many

    try many_blocks[0].putSlice("Name", "first");
    try many_blocks[1].putSlice("Name", "second");

    try ctx.putBlock("Loop", &many_blocks);

    const dbl_page = try t.buildFor(a, ctx);
    defer a.free(dbl_page);
    try std.testing.expectEqualStrings(dbl_expected, dbl_page);

    //many_blocks[0].raze();
    //many_blocks[1].raze();
}

test "directive For & For" {
    var a = std.testing.allocator;

    const blob =
        \\<div>
        \\  <For Loop>
        \\    <span><Name></span>
        \\    <For Numbers>
        \\      <Number>
        \\    </For>
        \\  </For>
        \\</div>
    ;

    const expected: []const u8 =
        \\<div>
        \\  <span>Alice</span>
        \\    A0
        \\    A1
        \\    A2
        \\    
        \\  <span>Bob</span>
        \\    B0
        \\    B1
        \\    B2
        \\    
        \\  
        \\</div>
    ;

    var t = Template{
        .alloc = null,
        //.path = "/dev/null",
        .name = "test",
        .blob = blob,
    };

    var ctx = Context.init(a);
    defer ctx.raze();
    var outer = [2]Context{
        Context.init(a),
        Context.init(a),
    };

    try outer[0].putSlice("Name", "Alice");
    //defer outer[0].raze();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const lput = "Number";

    var alice_inner: [3]Context = undefined;
    try outer[0].putBlock("Numbers", &alice_inner);
    for (0..3) |i| {
        alice_inner[i] = Context.init(a);
        try alice_inner[i].putSlice(
            lput,
            try std.fmt.allocPrint(aa, "A{}", .{i}),
        );
    }

    try outer[1].putSlice("Name", "Bob");
    //defer outer[1].raze();

    var bob_inner: [3]Context = undefined;
    try outer[1].putBlock("Numbers", &bob_inner);
    for (0..3) |i| {
        bob_inner[i] = Context.init(a);
        try bob_inner[i].putSlice(
            lput,
            try std.fmt.allocPrint(aa, "B{}", .{i}),
        );
    }

    try ctx.putBlock("Loop", &outer);

    const page = try t.buildFor(a, ctx);
    defer a.free(page);
    try std.testing.expectEqualStrings(expected, page);
}

test "directive With" {
    const a = std.testing.allocator;

    const blob =
        \\<div>
        \\  <With Thing>
        \\    <span><Thing></span>
        \\  </With>
        \\</div>
    ;

    const expected_empty: []const u8 =
        \\<div>
        \\  
        \\</div>
    ;
    var t = Template{
        .alloc = null,
        //.path = "/dev/null",
        .name = "test",
        .blob = blob,
    };

    var ctx = Context.init(a);
    defer ctx.raze();
    const page = try t.buildFor(a, ctx);
    defer a.free(page);
    try std.testing.expectEqualStrings(expected_empty, page);

    var thing = [1]Context{
        Context.init(a),
    };
    try thing[0].putSlice("Thing", "THING");
    try ctx.putBlock("Thing", &thing);

    const expected_thing: []const u8 =
        \\<div>
        \\  <span>THING</span>
        \\  
        \\</div>
    ;

    const page_thing = try t.buildFor(a, ctx);
    defer a.free(page_thing);
    try std.testing.expectEqualStrings(expected_thing, page_thing);
}
