const std = @import("std");
const build_mode = @import("builtin").mode;
const compiled = @import("templates-compiled");
pub const Structs = @import("templates-compiled-structs");
const isWhitespace = std.ascii.isWhitespace;
const indexOf = std.mem.indexOf;
const indexOfPos = std.mem.indexOfPos;
const lastIndexOf = std.mem.lastIndexOf;
const count = std.mem.count;

const Allocator = std.mem.Allocator;

const HTML = @import("html.zig");
const Pages = @import("template/page.zig");
pub const Page = Pages.Page;
pub const PageRuntime = Pages.PageRuntime;

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

pub const Context = DataMap;

// TODO rename this to... uhhh Map maybe?
//
pub const DataMap = struct {
    pub const Pair = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const Data = union(enum) {
        slice: []const u8,
        block: []DataMap,
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

            pub fn buildUnsanitized(self: Self, a: Allocator, ctx: *DataMap) !void {
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

            pub fn build(self: Self, a: Allocator, ctx: *DataMap) !void {
                if (comptime @import("builtin").zig_version.minor >= 12) {
                    if (std.meta.hasMethod(T, "contextBuilder")) {
                        return self.from.contextBuilder(a, ctx);
                    }
                }

                return self.buildUnsanitized(a, ctx);
            }
        };
    }

    pub fn init(a: Allocator) DataMap {
        return DataMap{
            .ctx = HashMap.init(a),
        };
    }

    pub fn initWith(a: Allocator, data: []const Pair) !DataMap {
        var ctx = DataMap.init(a);
        for (data) |d| {
            ctx.putSlice(d.name, d.value) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => unreachable,
            };
        }
        return ctx;
    }

    pub fn initBuildable(a: Allocator, buildable: anytype) !DataMap {
        var ctx = DataMap.init(a);
        const builder = buildable.builder();
        try builder.build(a, &ctx);
        return ctx;
    }

    pub fn raze(self: *DataMap) void {
        var itr = self.ctx.iterator();
        while (itr.next()) |*n| {
            switch (n.value_ptr.*) {
                .slice, .reader => continue,
                .block => |*block| for (block.*) |*b| b.raze(),
            }
        }
        self.ctx.deinit();
    }

    pub fn put(self: *DataMap, name: []const u8, value: Data) !void {
        try self.ctx.put(name, value);
    }

    pub fn get(self: DataMap, name: []const u8) ?Data {
        return self.ctx.get(name);
    }

    pub fn putSlice(self: *DataMap, name: []const u8, value: []const u8) !void {
        if (comptime build_mode == .Debug)
            if (!std.ascii.isUpper(name[0]))
                std.debug.print("Warning Template can't resolve {s}\n", .{name});
        try self.ctx.put(name, .{ .slice = value });
    }

    pub fn getSlice(self: DataMap, name: []const u8) ?[]const u8 {
        return switch (self.getNext(name) orelse return null) {
            .slice => |s| s,
            .block => unreachable,
            .reader => unreachable,
        };
    }

    /// Memory of block is managed by the caller. Calling raze will not free the
    /// memory from within.
    pub fn putBlock(self: *DataMap, name: []const u8, block: []DataMap) !void {
        try self.ctx.put(name, .{ .block = block });
    }

    pub fn getBlock(self: DataMap, name: []const u8) !?[]const DataMap {
        return switch (self.ctx.get(name) orelse return null) {
            // I'm sure this hack will live forever, I'm abusing With to be
            // an IF here, without actually implementing IF... sorry!
            //std.debug.print("Error: get [{s}] required Block, found slice\n", .{name});
            .slice, .reader => return error.NotABlock,
            .block => |b| b,
        };
    }

    pub fn putReader(self: *DataMap, name: []const u8, value: []const u8) !void {
        try self.putSlice(name, value);
    }

    pub fn getReader(self: DataMap, name: []const u8) ?std.io.AnyReader {
        switch (self.ctx.get(name) orelse return null) {
            .slice, .block => return error.NotAReader,
            .reader => |r| return r,
        }
        comptime unreachable;
    }
};

pub const TemplateRuntime = struct {
    name: []const u8 = "undefined",
    blob: []const u8,
};

pub const Template = struct {
    // path: []const u8,
    name: []const u8 = "undefined",
    blob: []const u8,
    parent: ?*const Template = null,

    pub fn initWith(self: *Template, a: Allocator, data: []struct { name: []const u8, val: []const u8 }) !void {
        self.init(a);
        for (data) |d| {
            try self.ctx.putSlice(d.name, d.value);
        }
    }

    pub fn page(self: Template, data: DataMap) PageRuntime(DataMap) {
        return PageRuntime(DataMap).init(.{ .name = self.name, .blob = self.blob }, data);
    }

    pub fn pageOf(self: Template, comptime Kind: type, data: Kind) PageRuntime(Kind) {
        return PageRuntime(Kind).init(.{ .name = self.name, .blob = self.blob }, data);
    }

    pub fn format(_: Template, comptime _: []const u8, _: std.fmt.FormatOptions, _: anytype) !void {
        comptime unreachable;
    }
};

pub const Directive = struct {
    kind: Kind,
    end: usize,

    pub const Kind = union(enum) {
        noun: Noun,
        verb: Verb,
    };
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
        whitespace: []const u8,
        word: Word,

        const Word = enum {
            foreach,
            forrow,
            with,
        };

        const Positions = struct {
            start: usize,
            start_ws: usize,
            end: usize,
            end_ws: usize,
            width: usize,
        };

        pub fn init(noun: []const u8, verb: []const u8, blob: []const u8) ?Directive {
            var pos: Positions = undefined;
            var word: Word = undefined;
            if (std.mem.eql(u8, noun, "For")) {
                pos = calcPos("For", blob, verb) orelse return null;
                word = .foreach;
            } else if (std.mem.eql(u8, noun, "ForRow")) {
                pos = calcPos("ForRow", blob, verb) orelse return null;
                word = .forrow;
            } else if (std.mem.eql(u8, noun, "With")) {
                pos = calcPos("With", blob, verb) orelse return null;
                word = .with;
            } else return null;

            std.debug.assert(pos.width > 1);
            return .{
                .end = pos.end,
                .kind = .{
                    .verb = .{
                        .vari = verb[1..pos.width],
                        .blob = blob[pos.start..pos.end_ws],
                        .whitespace = blob[pos.start_ws..pos.end_ws],
                        .word = word,
                    },
                },
            };
        }

        fn calcPos(comptime keyword: []const u8, blob: []const u8, verb: []const u8) ?Positions {
            const open: *const [keyword.len + 2]u8 = "<" ++ keyword ++ " ";
            const close: *const [keyword.len + 3]u8 = "</" ++ keyword ++ ">";

            var start = 1 + (indexOf(u8, blob, ">") orelse return null);
            var close_pos: usize = indexOfPos(u8, blob, 0, close) orelse return null;
            var skip = count(u8, blob[start..close_pos], open);
            while (skip > 0) : (skip -= 1) {
                close_pos = indexOfPos(u8, blob, close_pos + 1, close) orelse close_pos;
            }

            const end = close_pos + close.len;
            const end_ws = end - close.len;
            const start_ws = start;
            while (start < end and isWhitespace(blob[start])) : (start +|= 1) {}

            //while (endws > start and isWhitespace(blob[endws])) : (endws -|= 1) {}
            //endws += 1;

            var width: usize = 1;
            while (width < verb.len and validChar(verb[width])) {
                width += 1;
            }
            return .{
                .start = start,
                .start_ws = start_ws,
                .width = width,
                .end = end,
                .end_ws = end_ws,
            };
        }

        pub fn doTyped(self: Verb, T: type, ctx: anytype, out: anytype) anyerror!void {
            var local: [0xff]u8 = undefined;
            const realname = local[0..makeFieldName(self.vari, &local)];
            inline for (std.meta.fields(T)) |field| {
                if (field.type == []const u8 or
                    field.type == ?[]const u8) continue;
                switch (@typeInfo(field.type)) {
                    .Pointer => {
                        if (std.mem.eql(u8, field.name, realname)) {
                            const child = @field(ctx, field.name);
                            for (child) |each| {
                                switch (field.type) {
                                    []const []const u8 => {
                                        std.debug.assert(self.word == .forrow);
                                        try out.writeAll(each);
                                        try out.writeAll(self.whitespace);
                                    },
                                    else => {
                                        std.debug.assert(self.word == .foreach);
                                        try self.forEachTyped(@TypeOf(each), each, out);
                                    },
                                }
                            }
                        }
                    },
                    .Optional => {
                        if (std.mem.eql(u8, field.name, realname)) {
                            const child = @field(ctx, field.name);
                            if (child) |exists| {
                                std.debug.assert(self.word == .with);
                                try self.withTyped(@TypeOf(exists), exists, out);
                            }
                        }
                    },
                    else => comptime unreachable,
                }
            }
        }

        pub fn do(self: Verb, ctx: *const DataMap, out: anytype) anyerror!void {
            if (ctx.getBlock(self.vari) catch |err| switch (err) {
                error.NotABlock => ctx[0..1],
                else => return err,
            }) |block| {
                switch (self.word) {
                    .foreach => for (block) |s| try self.forEach(s, out),
                    .forrow => for (block) |s| try self.forEach(s, out),
                    .with => {
                        std.debug.assert(block.len == 1);
                        try self.with(block[0], out);
                    },
                }
                return;
            } else if (self.word == .foreach) {
                std.debug.print("<For {s}> ctx block missing.\n", .{self.vari});
            }
        }

        pub fn forEachTyped(self: Verb, T: type, data: T, out: anytype) anyerror!void {
            var p = PageRuntime(T){
                .data = data,
                .template = .{
                    .name = self.vari,
                    .blob = self.blob,
                },
            };
            try p.format("", .{}, out);
        }

        pub fn forEach(self: Verb, block: DataMap, out: anytype) anyerror!void {
            try self.forEachTyped(DataMap, block, out);
        }

        pub fn withTyped(self: Verb, T: type, block: T, out: anytype) anyerror!void {
            var p = PageRuntime(T){
                .data = block,
                .template = .{
                    .name = self.vari,
                    .blob = self.blob,
                },
            };
            try p.format("", .{}, out);
        }

        pub fn with(self: Verb, data: DataMap, out: anytype) anyerror!void {
            return try self.withTyped(DataMap, data, out);
        }
    };

    pub fn init(str: []const u8) ?Directive {
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
        } else if (Verb.init(vari, verb, str)) |kind| {
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

/// TODO remove/replace
/// Please use findTemplate instead
pub const find = findTemplate;

pub fn findTemplate(comptime name: []const u8) Template {
    inline for (builtin) |bi| {
        if (comptime std.mem.eql(u8, bi.name, name)) {
            return bi;
        }
    }
    @compileError("template " ++ name ++ " not found!");
}

pub fn PageData(comptime name: []const u8) type {
    const template = findTemplate(name);
    const page_data = comptime findPageType(name);
    return Page(template, page_data);
}

fn intToWord(in: u8) []const u8 {
    return switch (in) {
        '4' => "Four",
        '5' => "Five",
        else => unreachable,
    };
}

pub fn makeStructName(comptime in: []const u8, comptime out: []u8) usize {
    var ltail = in;
    if (comptime std.mem.lastIndexOf(u8, in, "/")) |i| {
        ltail = ltail[i..];
    }

    var i = 0;
    var next_upper = true;
    inline for (ltail) |chr| {
        switch (chr) {
            'a'...'z', 'A'...'Z' => {
                if (next_upper) {
                    out[i] = std.ascii.toUpper(chr);
                } else {
                    out[i] = chr;
                }
                next_upper = false;
                i += 1;
            },
            '0'...'9' => {
                for (intToWord(chr)) |cchr| {
                    out[i] = cchr;
                    i += 1;
                }
            },
            '-', '_', '.' => {
                next_upper = true;
            },
            else => {},
        }
    }

    return i;
}

pub fn makeFieldName(in: []const u8, out: []u8) usize {
    var i: usize = 0;
    for (in) |chr| {
        switch (chr) {
            'a'...'z' => {
                out[i] = chr;
                i += 1;
            },
            'A'...'Z' => {
                if (i != 0) {
                    out[i] = '_';
                    i += 1;
                }
                out[i] = std.ascii.toLower(chr);
                i += 1;
            },
            '0'...'9' => {
                for (intToWord(chr)) |cchr| {
                    out[i] = cchr;
                    i += 1;
                }
            },
            '-', '_', '.' => {
                out[i] = '_';
                i += 1;
            },
            else => {},
        }
    }

    return i;
}

pub fn findPageType(comptime name: []const u8) type {
    var local: [0xFFFF]u8 = undefined;
    const llen = comptime makeStructName(name, &local);
    return @field(Structs, local[0..llen]);
}

test "build.zig included templates" {
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
    const tmpl = find("user_commits.html");
    _ = tmpl;
}

test "directive something" {
    var a = std.testing.allocator;
    var t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<Something>",
    };

    var ctx = DataMap.init(a);
    try ctx.putSlice("Something", "Some Text Here");
    defer ctx.raze();
    const p = try t.page(ctx).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings("Some Text Here", p);
}

test "directive nothing" {
    var a = std.testing.allocator;
    var t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<!-- nothing -->",
    };

    const p = try t.page(DataMap.init(a)).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings("<!-- nothing -->", p);
}

test "directive nothing new" {
    var a = std.testing.allocator;
    var t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<Nothing>",
    };

    const p = try t.page(DataMap.init(a)).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings("<Nothing>", p);
}

test "directive ORELSE" {
    var a = std.testing.allocator;
    var t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<This ORELSE string until end>",
    };

    const p = try t.page(DataMap.init(a)).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings("string until end", p);
}

test "directive ORNULL" {
    var a = std.testing.allocator;
    var t = Template{
        //.path = "/dev/null",
        .name = "test",
        // Invalid because 'string until end' is known to be unreachable
        .blob = "<This ORNULL string until end>",
    };

    const p = try t.page(DataMap.init(a)).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings("<This ORNULL string until end>", p);

    t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<This ORNULL>",
    };

    const nullpage = try t.page(DataMap.init(a)).build(a);
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
        //.path = "/dev/null",
        .name = "test",
        .blob = blob,
    };

    var ctx = DataMap.init(a);
    defer ctx.raze();
    var blocks: [1]DataMap = [1]DataMap{
        DataMap.init(a),
    };
    try blocks[0].putSlice("Name", "not that");
    // We have to raze because it will be over written
    defer blocks[0].raze();
    try ctx.putBlock("Loop", &blocks);

    const p = try t.page(ctx).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings(expected, p);

    // many
    var many_blocks: [2]DataMap = [_]DataMap{
        DataMap.init(a),
        DataMap.init(a),
    };
    // what... 2 is many

    try many_blocks[0].putSlice("Name", "first");
    try many_blocks[1].putSlice("Name", "second");

    try ctx.putBlock("Loop", &many_blocks);

    const dbl_page = try t.page(ctx).build(a);
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
        //.path = "/dev/null",
        .name = "test",
        .blob = blob,
    };

    var ctx = DataMap.init(a);
    defer ctx.raze();
    var outer = [2]DataMap{
        DataMap.init(a),
        DataMap.init(a),
    };

    try outer[0].putSlice("Name", "Alice");
    //defer outer[0].raze();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const lput = "Number";

    var alice_inner: [3]DataMap = undefined;
    try outer[0].putBlock("Numbers", &alice_inner);
    for (0..3) |i| {
        alice_inner[i] = DataMap.init(a);
        try alice_inner[i].putSlice(
            lput,
            try std.fmt.allocPrint(aa, "A{}", .{i}),
        );
    }

    try outer[1].putSlice("Name", "Bob");
    //defer outer[1].raze();

    var bob_inner: [3]DataMap = undefined;
    try outer[1].putBlock("Numbers", &bob_inner);
    for (0..3) |i| {
        bob_inner[i] = DataMap.init(a);
        try bob_inner[i].putSlice(
            lput,
            try std.fmt.allocPrint(aa, "B{}", .{i}),
        );
    }

    try ctx.putBlock("Loop", &outer);

    const p = try t.page(ctx).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings(expected, p);
}

test "directive for then for" {
    var a = std.testing.allocator;

    const blob =
        \\<div>
        \\  <For Loop>
        \\    <span><Name></span>
        \\  </For>
        \\  <For Numbers>
        \\    <Number>
        \\  </For>
        \\</div>
    ;

    const expected: []const u8 =
        \\<div>
        \\  <span>Alice</span>
        \\  <span>Bob</span>
        \\  
        \\  A0
        \\  A1
        \\  A2
        \\  
        \\</div>
    ;

    const FTF = struct {
        const Loop = struct {
            name: []const u8,
        };
        const Numbers = struct {
            number: []const u8,
        };

        loop: []const Loop,
        numbers: []const Numbers,
    };

    const t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = blob,
    };
    const page = Page(t, FTF);

    const loop = [2]FTF.Loop{
        .{ .name = "Alice" },
        .{ .name = "Bob" },
    };
    const numbers = [3]FTF.Numbers{
        .{ .number = "A0" },
        .{ .number = "A1" },
        .{ .number = "A2" },
    };
    const p = page.init(.{
        .loop = loop[0..],
        .numbers = numbers[0..],
    });
    const build = try p.build(a);
    defer a.free(build);
    try std.testing.expectEqualStrings(expected, build);
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
    // trailing spaces expected and required
    try std.testing.expect(std.mem.count(u8, expected_empty, "  \n") == 1);
    var t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = blob,
    };

    var ctx = DataMap.init(a);
    defer ctx.raze();
    const p = try t.page(ctx).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings(expected_empty, p);

    var thing = [1]DataMap{
        DataMap.init(a),
    };
    try thing[0].putSlice("Thing", "THING");
    try ctx.putBlock("Thing", &thing);

    const expected_thing: []const u8 =
        \\<div>
        \\  <span>THING</span>
        \\  
        \\</div>
    ;

    const page_thing = try t.page(ctx).build(a);
    defer a.free(page_thing);
    try std.testing.expectEqualStrings(expected_thing, page_thing);
}

test "directive ForRow" {
    var a = std.testing.allocator;

    const blob =
        \\<div>
        \\  <ForRow Slice>
        \\  </ForRow>
        \\</div>
        \\
    ;

    const expected: []const u8 =
        \\<div>
        \\  Alice
        \\  Bob
        \\  Charlie
        \\  Eve
        \\  
        \\</div>
        \\
    ;

    const FE = struct {
        slice: []const []const u8,
    };

    const t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = blob,
    };
    const page = Page(t, FE);

    const slice = FE{
        .slice = &[_][]const u8{
            "Alice",
            "Bob",
            "Charlie",
            "Eve",
        },
    };
    const p = page.init(slice);
    const build = try p.build(a);
    defer a.free(build);
    try std.testing.expectEqualStrings(expected, build);
}
