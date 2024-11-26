const std = @import("std");
const build_mode = @import("builtin").mode;
const compiled = @import("templates-compiled");
pub const Structs = @import("templates-compiled-structs");
const Allocator = std.mem.Allocator;

const HTML = @import("html.zig");
const Pages = @import("template/page.zig");
pub const Directive = @import("template/directive.zig");

pub const Page = Pages.Page;
pub const PageRuntime = Pages.PageRuntime;

const MAX_BYTES = 2 <<| 15;
const TEMPLATE_PATH = "templates/";

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
    var t = findTemplate(name);
    t.init(a);
    return t;
}

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

test findTemplate {
    const tmpl = findTemplate("user_commits.html");
    try std.testing.expectEqualStrings("user_commits.html", tmpl.name);
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
    const a = std.testing.allocator;
    const t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<Nothing>",
    };

    const ctx = .{};

    // TODO is this still the expected behavior
    //const p = Page(t, @TypeOf(ctx)).init(.{}).build(a);
    //try std.testing.expectError(error.VariableMissing, p);

    const p = try Page(t, @TypeOf(ctx)).init(.{}).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings("<Nothing>", p);
}

test "directive ORELSE" {
    var a = std.testing.allocator;
    const t = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<This default='string until end'>",
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
        .blob = "<This ornull string until end>",
    };

    const ctx = .{
        .this = @as(?[]const u8, null),
    };

    const p = try Page(t, @TypeOf(ctx)).init(ctx).build(a);
    defer a.free(p);
    try std.testing.expectEqualStrings("", p);

    const t2 = Template{
        //.path = "/dev/null",
        .name = "test",
        .blob = "<This ornull>",
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
