const std = @import("std");
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const indexOf = std.mem.indexOf;
const indexOfPos = std.mem.indexOfPos;
const indexOfAnyPos = std.mem.indexOfAnyPos;
const indexOfScalar = std.mem.indexOfScalar;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const isUpper = std.ascii.isUpper;
const count = std.mem.count;
const isWhitespace = std.ascii.isWhitespace;

pub const Directive = @This();

const PageRuntime = @import("page.zig").PageRuntime;

const Template = @import("../template.zig");

const dynamic = &Template.dynamic;
const builtin = Template.builtin;
const makeFieldName = Template.makeFieldName;

verb: Verb,
noun: []const u8,
otherwise: Otherwise = .{ .ign = {} },
known_type: ?KnownType = null,
end: usize,

pub const Otherwise = union(enum) {
    ign: void,
    del: void,
    str: []const u8,
    template: Template.Template,
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

fn validChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z' => true,
        '-', '_', '.', ':' => true,
        else => false,
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

fn getDynamic(name: []const u8) ?Template.Template {
    for (0..dynamic.*.len) |i| {
        if (eql(u8, dynamic.*[i].name, name)) {
            return dynamic.*[i];
        }
    }
    return null;
}

fn getBuiltin(name: []const u8) ?Template.Template {
    for (0..builtin.len) |i| {
        if (eql(u8, builtin[i].name, name)) {
            return builtin[i];
        }
    }
    return null;
}

fn typeField(T: type, name: []const u8, data: T) ?[]const u8 {
    if (@typeInfo(T) != .Struct) return null;
    var local: [0xff]u8 = undefined;
    const realname = local[0..makeFieldName(name, &local)];
    inline for (std.meta.fields(T)) |field| {
        if (eql(u8, field.name, realname)) {
            switch (field.type) {
                []const u8,
                ?[]const u8,
                => return @field(data, field.name),

                else => return null,
            }
        }
    }
    return null;
}

pub fn format(d: Directive, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
    _ = d;
    _ = out;
    unreachable;
}

pub fn formatTyped(d: Directive, comptime T: type, ctx: T, out: anytype) !void {
    switch (d.verb) {
        .variable => {
            const noun = d.noun;
            const var_name = typeField(T, noun, ctx);
            if (var_name) |data_blob| {
                try out.writeAll(data_blob);
            } else {
                //if (DEBUG) std.debug.print("[missing var {s}]\n", .{noun.vari});
                switch (d.otherwise) {
                    .str => |str| try out.writeAll(str),
                    // Not really an error, just instruct caller to print original text
                    .ign => return error.IgnoreDirective,
                    .del => {},
                    .template => |subt| {
                        if (T == usize) unreachable;
                        inline for (std.meta.fields(T)) |field|
                            switch (@typeInfo(field.type)) {
                                .Optional => |otype| {
                                    if (otype.child == []const u8) continue;

                                    var local: [0xff]u8 = undefined;
                                    const realname = local[0..makeFieldName(noun[1 .. noun.len - 5], &local)];
                                    if (std.mem.eql(u8, field.name, realname)) {
                                        if (@field(ctx, field.name)) |subdata| {
                                            var subpage = subt.pageOf(otype.child, subdata);
                                            try subpage.format("{}", .{}, out);
                                        } else std.debug.print(
                                            "sub template data was null for {s}\n",
                                            .{field.name},
                                        );
                                    }
                                },
                                .Struct => {
                                    if (std.mem.eql(u8, field.name, noun)) {
                                        const subdata = @field(ctx, field.name);
                                        var subpage = subt.pageOf(@TypeOf(subdata), subdata);
                                        try subpage.format("{}", .{}, out);
                                    }
                                },
                                else => {}, //@compileLog(field.type),
                            };
                    },
                    .blob => unreachable,
                }
            }
        },
        else => d.doTyped(T, ctx, out) catch unreachable,
    }
}
