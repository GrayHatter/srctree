const std = @import("std");
const build_mode = @import("builtin").mode;
const compiled = @import("templates-compiled");
pub const Structs = @import("templates-compiled-structs");
const Allocator = std.mem.Allocator;
const isWhitespace = std.ascii.isWhitespace;
const indexOf = std.mem.indexOf;
const indexOfScalar = std.mem.indexOfScalar;
const indexOfPos = std.mem.indexOfPos;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const indexOfAnyPos = std.mem.indexOfAnyPos;
const lastIndexOf = std.mem.lastIndexOf;
const startsWith = std.mem.startsWith;
const count = std.mem.count;
const eql = std.mem.eql;
const isUpper = std.ascii.isUpper;

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

    pub fn pageOf(self: Template, comptime Kind: type, data: Kind) PageRuntime(Kind) {
        return PageRuntime(Kind).init(.{ .name = self.name, .blob = self.blob }, data);
    }

    pub fn format(_: Template, comptime _: []const u8, _: std.fmt.FormatOptions, _: anytype) !void {
        comptime unreachable;
    }
};

pub const Directive = struct {
    verb: Verb,
    noun: []const u8,
    otherwise: Otherwise = .{ .ign = {} },
    known_type: ?KnownType = null,
    end: usize,

    pub const Otherwise = union(enum) {
        ign: void,
        del: void,
        str: []const u8,
        template: Template,
        blob: Blob,
        pub const Blob = struct {
            trimmed: []const u8,
            whitespace: []const u8,
        };
    };

    pub const Verb = enum {
        variable,
        foreach,
        split,
        with,
        build,
        typed,
    };

    pub const KnownType = enum {
        usize,
        isize,
        @"?usize",
    };

    const Positions = struct {
        start: usize,
        start_ws: usize,
        end: usize,
        end_ws: usize,
        width: usize,
    };

    pub fn initVerb(verb: []const u8, noun: []const u8, blob: []const u8) ?Directive {
        var otherw: struct { Directive.Otherwise, usize } = undefined;
        var word: Verb = undefined;
        if (eql(u8, verb, "For")) {
            otherw = calcBody("For", noun, blob) orelse return null;
            word = .foreach;
        } else if (eql(u8, verb, "Split")) {
            otherw = calcBody("Split", noun, blob) orelse return null;
            word = .split;
        } else if (eql(u8, verb, "With")) {
            otherw = calcBody("With", noun, blob) orelse return null;
            word = .with;
        } else if (eql(u8, verb, "With")) {
            otherw = calcBody("With", noun, blob) orelse return null;
            word = .with;
        } else if (eql(u8, verb, "Build")) {
            const b_noun = noun[1..(indexOfScalarPos(u8, noun, 1, ' ') orelse return null)];
            const tail = noun[b_noun.len + 1 ..];
            const b_html = tail[1..(indexOfScalarPos(u8, tail, 2, ' ') orelse return null)];
            if (getBuiltin(b_html)) |bi| {
                return Directive{
                    .verb = .build,
                    .noun = b_noun,
                    .otherwise = .{ .template = bi },
                    .end = verb.len + 1 + noun.len,
                };
            } else if (getDynamic(b_html)) |bi| {
                return Directive{
                    .verb = .build,
                    .noun = b_noun,
                    .otherwise = .{ .template = bi },
                    .end = verb.len + 1 + noun.len,
                };
            } else return null;
        } else return null;

        // TODO convert to while
        //inline for (Word) |tag_name| {
        //    if (eql(u8, noun, @tagName(tag_name))) {
        //        pos = calcPos(@tagName(tag_name), blob, verb) orelse return null;
        //        word = tag_name;
        //        break;
        //    }
        //} else return null;

        var start = (indexOf(u8, noun, ">") orelse return null);
        if (noun[start - 1] == '/') start -= 1;
        return .{
            .verb = word,
            .noun = noun[1..start],
            .otherwise = otherw[0],
            .end = otherw[1],
        };
    }

    fn calcBodyS(comptime _: []const u8, _: []const u8, blob: []const u8, end: usize) ?struct { Otherwise, usize } {
        if (blob.len <= end) return null;
        return .{ .{ .ign = {} }, end + 1 };
    }

    fn calcBody(comptime keyword: []const u8, noun: []const u8, blob: []const u8) ?struct { Otherwise, usize } {
        const open: *const [keyword.len + 2]u8 = "<" ++ keyword ++ " ";
        const close: *const [keyword.len + 3]u8 = "</" ++ keyword ++ ">";

        if (!startsWith(u8, blob, open)) @panic("error compiling template");
        var shape_i: usize = open.len;
        while (shape_i < blob.len and blob[shape_i] != '/' and blob[shape_i] != '>')
            shape_i += 1;
        switch (blob[shape_i]) {
            '/' => return calcBodyS(keyword, noun, blob, shape_i + 1),
            '>' => {},
            else => return null,
        }

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
        while (width < noun.len and validChar(noun[width])) {
            width += 1;
        }
        return .{ .{ .blob = .{
            .trimmed = blob[start..end_ws],
            .whitespace = blob[start_ws..end_ws],
        } }, end };
    }

    fn isStringish(t: type) bool {
        return switch (t) {
            []const u8, ?[]const u8 => true,
            else => false,
        };
    }

    pub fn doTyped(self: Directive, T: type, ctx: anytype, out: anytype) anyerror!void {
        //@compileLog(T);
        var local: [0xff]u8 = undefined;
        const realname = local[0..makeFieldName(self.noun, &local)];
        switch (@typeInfo(T)) {
            .Struct => {
                inline for (std.meta.fields(T)) |field| {
                    if (comptime isStringish(field.type)) continue;
                    switch (@typeInfo(field.type)) {
                        .Pointer => {
                            if (eql(u8, field.name, realname)) {
                                const child = @field(ctx, field.name);
                                for (child) |each| {
                                    switch (field.type) {
                                        []const []const u8 => {
                                            std.debug.assert(self.verb == .split);
                                            try out.writeAll(each);
                                            try out.writeAll("\n");
                                            //try out.writeAll( self.otherwise.blob.whitespace);
                                        },
                                        else => {
                                            std.debug.assert(self.verb == .foreach);
                                            try self.forEachTyped(@TypeOf(each), each, out);
                                        },
                                    }
                                }
                            }
                        },
                        .Optional => {
                            if (eql(u8, field.name, realname)) {
                                //@compileLog("optional for {s}\n", field.name, field.type, T);
                                const child = @field(ctx, field.name);
                                if (child) |exists| {
                                    if (self.verb == .with)
                                        try self.withTyped(@TypeOf(exists), exists, out)
                                    else
                                        try self.doTyped(@TypeOf(exists), exists, out);
                                }
                            }
                        },
                        .Struct => {
                            if (eql(u8, field.name, realname)) {
                                const child = @field(ctx, field.name);
                                std.debug.assert(self.verb == .build);
                                try self.withTyped(@TypeOf(child), child, out);
                            }
                        },
                        .Int => |int| {
                            if (eql(u8, field.name, realname)) {
                                std.debug.assert(int.bits == 64);
                                try std.fmt.formatInt(@field(ctx, field.name), 10, .lower, .{}, out);
                            }
                        },
                        else => comptime unreachable,
                    }
                }
            },
            .Int => {
                //std.debug.assert(int.bits == 64);
                try std.fmt.formatInt(ctx, 10, .lower, .{}, out);
            },
            else => comptime unreachable,
        }
    }

    pub fn forEachTyped(self: Directive, T: type, data: T, out: anytype) anyerror!void {
        var p = PageRuntime(T){
            .data = data,
            .template = .{
                .name = self.noun,
                .blob = self.otherwise.blob.trimmed,
            },
        };
        try p.format("", .{}, out);
    }

    pub fn withTyped(self: Directive, T: type, block: T, out: anytype) anyerror!void {
        var p = PageRuntime(T){
            .data = block,
            .template = if (self.otherwise == .template) self.otherwise.template else .{
                .name = self.noun,
                .blob = self.otherwise.blob.trimmed,
            },
        };
        try p.format("", .{}, out);
    }

    fn getDynamic(name: []const u8) ?Template {
        for (0..dynamic.len) |i| {
            if (eql(u8, dynamic[i].name, name)) {
                return dynamic[i];
            }
        }
        return null;
    }

    fn getBuiltin(name: []const u8) ?Template {
        for (0..builtin.len) |i| {
            if (eql(u8, builtin[i].name, name)) {
                return builtin[i];
            }
        }
        return null;
    }

    pub fn init(str: []const u8) ?Directive {
        if (str.len < 2) return null;
        if (!isUpper(str[1]) and str[1] != '_') return null;
        const end = 1 + (indexOf(u8, str, ">") orelse return null);
        const tag = str[0..end];
        const verb = tag[1 .. indexOfScalar(u8, tag, ' ') orelse tag.len - 1];

        if (verb.len == tag.len - 2) {
            if (verb[0] == '_') {
                if (getBuiltin(verb)) |bi| {
                    return Directive{
                        .noun = verb,
                        .verb = .variable,
                        .otherwise = .{ .template = bi },
                        .end = end,
                    };
                }
            }
            return Directive{
                .verb = .variable,
                .noun = verb,
                .end = end,
            };
        }

        var width: usize = 1;
        while (width < str.len and validChar(str[width])) {
            width += 1;
        }

        const noun = tag[verb.len + 1 ..];
        if (initVerb(verb, noun, str)) |kind| {
            return kind;
        }

        var known: ?KnownType = null;
        if (indexOfScalar(u8, noun, '=')) |i| {
            if (i >= 4 and eql(u8, noun[i - 4 .. i], "type")) {
                const i_end = indexOfAnyPos(u8, noun, i, " /") orelse end - 1;
                const requested_type = std.mem.trim(u8, noun[i..i_end], " ='\"");
                inline for (std.meta.fields(KnownType)) |kt| {
                    if (eql(u8, requested_type, kt.name)) {
                        known = @enumFromInt(kt.value);
                        break;
                    }
                } else {
                    std.debug.print("Unable to resolve requested type {s}\n", .{requested_type});
                    unreachable;
                }
            }
        }
        if (startsWith(u8, noun, " ORELSE ")) {
            return Directive{
                .verb = .variable,
                .noun = verb,
                .otherwise = .{ .str = tag[width + 8 .. end - 1] },
                .end = end,
                .known_type = known,
            };
        } else if (startsWith(u8, noun, " ORNULL>")) {
            return Directive{
                .verb = .variable,
                .noun = verb,
                .otherwise = .{ .del = {} },
                .end = end,
                .known_type = known,
            };
        } else if (startsWith(u8, noun, " />")) {
            return Directive{
                .verb = .variable,
                .noun = verb,
                .end = end,
                .known_type = known,
            };
        } else if (known != null) {
            return Directive{
                .verb = .typed,
                .noun = verb,
                .end = end,
                .known_type = known,
            };
        } else return null;
    }
};

fn tailPath(path: []const u8) []const u8 {
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
            .name = tailPath(filedata.path),
            .blob = filedata.blob,
        };
    }
    break :blk t;
};

pub var dynamic: []const Template = undefined;

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
        const tail = tailPath(file.name);
        const name_ = try a.dupe(u8, tail);
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
    const a = std.testing.allocator;
    const t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<Something>",
    };

    const ctx = .{
        .something = @as([]const u8, "Some Text Here"),
    };
    const p = Page(t, @TypeOf(ctx)).init(ctx);
    const pg = try p.build(a);
    defer a.free(pg);
    try std.testing.expectEqualStrings("Some Text Here", pg);

    const t2 = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<Something />",
    };

    const ctx2 = .{
        .something = @as([]const u8, "Some Text Here"),
    };
    const p2 = Page(t2, @TypeOf(ctx2)).init(ctx2);
    const pg2 = try p2.build(a);
    defer a.free(pg2);
    try std.testing.expectEqualStrings("Some Text Here", pg2);
}

test "directive typed something" {
    var a = std.testing.allocator;

    const Something = struct {
        something: []const u8,
    };

    const t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<Something>",
    };

    const page = Page(t, Something);

    const p = page.init(.{
        .something = "Some Text Here",
    });

    const built = try p.build(a);
    defer a.free(built);
    try std.testing.expectEqualStrings("Some Text Here", built);
}

test "directive typed something /" {
    var a = std.testing.allocator;

    const Something = struct {
        something: []const u8,
    };

    const t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<Something />",
    };

    const page = Page(t, Something);

    const p = page.init(.{
        .something = "Some Text Here",
    });

    const built = try p.build(a);
    defer a.free(built);
    try std.testing.expectEqualStrings("Some Text Here", built);
}

test "directive nothing" {
    var a = std.testing.allocator;
    const t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<!-- nothing -->",
    };

    const ctx = .{};
    const page = Page(t, @TypeOf(ctx));

    const p = try page.init(ctx).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings("<!-- nothing -->", p);
}

test "directive nothing new" {
    var a = std.testing.allocator;
    const t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<Nothing>",
    };

    const ctx = .{};

    // TODO is this still the expected behavior
    const p = try Page(t, @TypeOf(ctx)).init(.{}).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings("<Nothing>", p);
}

test "directive ORELSE" {
    var a = std.testing.allocator;
    const t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<This ORELSE string until end>",
    };

    const ctx = .{
        .this = @as(?[]const u8, null),
    };

    const p = try Page(t, @TypeOf(ctx)).init(ctx).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings("string until end", p);
}

test "directive ORNULL" {
    var a = std.testing.allocator;
    const t = Template{
        //.path = "/dev/null",
        .name = "test",
        // Invalid because 'string until end' is known to be unreachable
        .blob = "<This ORNULL string until end>",
    };

    const ctx = .{
        .this = @as(?[]const u8, null),
    };

    const p = try Page(t, @TypeOf(ctx)).init(ctx).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings("<This ORNULL string until end>", p);

    const t2 = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<This ORNULL>",
    };

    const nullpage = try Page(t2, @TypeOf(ctx)).init(ctx).build(a);
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

    const t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = blob,
    };

    var ctx: struct { loop: []const struct { name: []const u8 } } = .{
        .loop = &.{
            .{ .name = "not that" },
        },
    };

    const p = try Page(t, @TypeOf(ctx)).init(ctx).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings(expected, p);

    ctx = .{
        .loop = &.{
            .{ .name = "first" },
            .{ .name = "second" },
        },
    };

    const dbl_page = try Page(t, @TypeOf(ctx)).init(ctx).build(a);
    defer a.free(dbl_page);
    try std.testing.expectEqualStrings(dbl_expected, dbl_page);
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
    ++ "\n    \n" ++
        \\  <span>Bob</span>
        \\    B0
        \\    B1
        \\    B2
    ++ "\n    \n  \n" ++
        \\</div>
    ;

    const t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = blob,
    };

    const ctx: struct {
        loop: []const struct {
            name: []const u8,
            numbers: []const struct {
                number: []const u8,
            },
        },
    } = .{
        .loop = &.{
            .{
                .name = "Alice",
                .numbers = &.{
                    .{ .number = "A0" },
                    .{ .number = "A1" },
                    .{ .number = "A2" },
                },
            },
            .{
                .name = "Bob",
                .numbers = &.{
                    .{ .number = "B0" },
                    .{ .number = "B1" },
                    .{ .number = "B2" },
                },
            },
        },
    };

    const p = try Page(t, @TypeOf(ctx)).init(ctx).build(a);
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
    ++ "\n  \n" ++
        \\  A0
        \\  A1
        \\  A2
    ++ "\n  \n" ++
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
    ++ "\n  \n" ++
        \\</div>
    ;
    // trailing spaces expected and required
    try std.testing.expect(std.mem.count(u8, expected_empty, "  \n") == 1);
    const t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = blob,
    };

    var ctx: struct {
        thing: ?struct {
            thing: []const u8,
        },
    } = .{
        .thing = null,
    };

    const page = Page(t, @TypeOf(ctx));
    const p = try page.init(ctx).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings(expected_empty, p);

    ctx = .{
        .thing = .{ .thing = "THING" },
    };

    const expected_thing: []const u8 =
        \\<div>
        \\  <span>THING</span>
    ++ "\n  \n" ++
        \\</div>
    ;

    const p2 = try page.init(ctx).build(a);
    defer a.free(p2);
    try std.testing.expectEqualStrings(expected_thing, p2);
}

test "directive Split" {
    var a = std.testing.allocator;

    const blob =
        \\<div>
        \\  <Split Slice />
        \\</div>
        \\
    ;

    const expected: []const u8 =
        \\<div>
        \\  Alice
        \\Bob
        \\Charlie
        \\Eve
    ++ "\n\n" ++
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

test "directive Build" {
    var a = std.testing.allocator;

    const blob =
        \\<Build Name _template.html />
    ;

    const expected: []const u8 =
        \\<div>
        \\AliceBobCharlieEve
        \\</div>
    ;

    const FE = struct {
        const This = struct {
            this: []const u8,
        };
        name: struct {
            slice: []const This,
        },
    };

    const t = Template{
        .name = "test",
        .blob = blob,
    };
    const page = Page(t, FE);

    dynamic = &[1]Template{
        .{
            .name = "_template.html",
            .blob = "<div>\n<For Slice><This></For>\n</div>",
        },
    };

    const slice = FE{
        .name = .{
            .slice = &[4]FE.This{
                .{ .this = "Alice" },
                .{ .this = "Bob" },
                .{ .this = "Charlie" },
                .{ .this = "Eve" },
            },
        },
    };
    const p = page.init(slice);
    const build = try p.build(a);
    defer a.free(build);
    try std.testing.expectEqualStrings(expected, build);
}

test "directive typed usize" {
    var a = std.testing.allocator;
    const blob = "<Number type=\"usize\" />";
    const expected: []const u8 = "420";

    const FE = struct { number: usize };

    const t = Template{ .name = "test", .blob = blob };
    const page = Page(t, FE);

    const slice = FE{ .number = 420 };
    const p = page.init(slice);
    const build = try p.build(a);
    defer a.free(build);
    try std.testing.expectEqualStrings(expected, build);
}

test "directive typed ?usize" {
    var a = std.testing.allocator;
    const blob = "<Number type=\"?usize\" />";
    const expected: []const u8 = "420";

    const FE = struct { number: ?usize };

    const t = Template{ .name = "test", .blob = blob };
    const page = Page(t, FE);

    const slice = FE{ .number = 420 };
    const p = page.init(slice);
    const build = try p.build(a);
    defer a.free(build);
    try std.testing.expectEqualStrings(expected, build);
}

test "directive typed ?usize null" {
    var a = std.testing.allocator;
    const blob = "<Number type=\"?usize\" />";
    const expected: []const u8 = "";

    const FE = struct { number: ?usize };

    const t = Template{ .name = "test", .blob = blob };
    const page = Page(t, FE);

    const slice = FE{ .number = null };
    const p = page.init(slice);
    const build = try p.build(a);
    defer a.free(build);
    try std.testing.expectEqualStrings(expected, build);
}

test "directive typed isize" {
    var a = std.testing.allocator;
    const blob = "<Number type=\"isize\" />";
    const expected: []const u8 = "-420";

    const FE = struct { number: isize };

    const t = Template{ .name = "test", .blob = blob };
    const page = Page(t, FE);

    const slice = FE{ .number = -420 };
    const p = page.init(slice);
    const build = try p.build(a);
    defer a.free(build);
    try std.testing.expectEqualStrings(expected, build);
}
