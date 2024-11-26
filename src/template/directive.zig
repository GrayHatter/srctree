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
const trim = std.mem.trim;
const trimLeft = std.mem.trimLeft;
const whitespace = std.ascii.whitespace[0..];

pub const Directive = @This();

const PageRuntime = @import("page.zig").PageRuntime;

const Template = @import("../template.zig");

const dynamic = &Template.dynamic;
const builtin = Template.builtin;
const makeFieldName = Template.makeFieldName;

verb: Verb,
noun: []const u8,
otherwise: Otherwise,
known_type: ?KnownType = null,
tag_block: []const u8,

pub const Otherwise = union(enum) {
    required: void,
    ignore: void,
    delete: void,
    default: []const u8,
    template: *const Template.Template,
    blob: []const u8,
};

pub const Verb = enum {
    variable,
    foreach,
    split,
    with,
    build,
};

pub const KnownType = enum {
    usize,
    isize,
    @"?usize",

    pub fn nullable(kt: KnownType) bool {
        return switch (kt) {
            .usize, .isize => false,
            .@"?usize" => true,
        };
    }
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
    const end = findTag(str) catch return null;
    const tag = str[0..end];
    const verb = tag[1 .. indexOfAnyPos(u8, tag, 1, " /") orelse tag.len - 1];

    if (verb.len == tag.len - 2) {
        if (initNoun(verb, tag)) |noun| {
            return noun;
        } else unreachable;
    }

    const noun = tag[verb.len + 1 .. tag.len - 1];
    if (initVerb(verb, noun, str)) |kind| {
        return kind;
    }

    if (initNoun(verb, tag)) |kind| {
        return kind;
    }
    return null;
}

fn initNoun(noun: []const u8, tag: []const u8) ?Directive {
    //std.debug.print("init noun {s}\n", .{noun});
    if (noun[0] == '_') if (getBuiltin(noun)) |bi| {
        return Directive{
            .noun = noun,
            .verb = .variable,
            .otherwise = .{ .template = bi },
            .tag_block = tag,
        };
    };

    var default_str: ?[]const u8 = null;
    var knownt: ?KnownType = null;
    var rem_attr = tag[noun.len + 1 .. tag.len - 1];
    while (indexOfScalar(u8, rem_attr, '=') != null) {
        if (findAttribute(rem_attr)) |attr| {
            if (eql(u8, attr.name, "type")) {
                inline for (std.meta.fields(KnownType)) |kt| {
                    if (eql(u8, attr.value, kt.name)) {
                        knownt = @enumFromInt(kt.value);
                        break;
                    }
                } else {
                    std.debug.print("Unable to resolve requested type '{s}'\n", .{attr.value});
                    unreachable;
                }
            } else if (eql(u8, attr.name, "default")) {
                default_str = attr.value;
            }
            rem_attr = rem_attr[attr.len..];
        } else |err| switch (err) {
            error.AttrInvalid => break,
            else => unreachable,
        }
    }

    return Directive{
        .verb = .variable,
        .noun = noun,
        .otherwise = if (default_str) |str|
            .{ .default = str }
        else if (indexOf(u8, tag, " ornull")) |_|
            .delete
        else if (knownt) |kn|
            if (kn.nullable())
                .delete
            else
                .required
        else
            .required,
        .known_type = knownt,
        .tag_block = tag,
    };
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
                .tag_block = blob[0 .. verb.len + 2 + noun.len],
            };
        } else if (getDynamic(b_html)) |bi| {
            return Directive{
                .verb = .build,
                .noun = b_noun,
                .otherwise = .{ .template = bi },
                .tag_block = blob[0 .. verb.len + 2 + noun.len],
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

    var end = (indexOf(u8, noun, ">") orelse noun.len);
    if (noun[end - 1] == '/') end -= 1;
    return .{
        .verb = word,
        .noun = noun[1..end],
        .otherwise = otherw[0],
        .tag_block = blob[0..otherw[1]],
    };
}

fn findTag(blob: []const u8) !usize {
    return 1 + (indexOf(u8, blob, ">") orelse return error.TagInvalid);
}

const TAttr = struct {
    name: []const u8,
    value: []const u8,
    len: usize,
};

fn findAttribute(tag: []const u8) !TAttr {
    const equi = indexOfScalar(u8, tag, '=') orelse return error.AttrInvalid;
    const name = trim(u8, tag[0..equi], whitespace);
    var value = trim(u8, tag[equi + 1 ..], whitespace);

    var end: usize = equi + 1;
    while (end < tag.len and isWhitespace(tag[end])) end += 1;
    while (end < tag.len) {
        // TODO rewrite with tagged switch syntax
        switch (tag[end]) {
            '\n', '\r', '\t', ' ' => end += 1,
            '\'', '"' => |qut| {
                end += 1;
                while (end <= tag.len and tag[end] != qut) end += 1;
                if (end == tag.len) return error.AttrInvalid;
                if (tag[end] != qut) return error.AttrInvalid else end += 1;
                value = trim(u8, tag[equi + 1 .. end], whitespace.* ++ &[_]u8{ qut, '=', '<', '>', '/' });
                break;
            },
            else => {
                while (end < tag.len and !isWhitespace(tag[end])) end += 1;
            },
        }
    }
    return .{
        .name = name,
        .value = value,
        .len = end,
    };
}

test findAttribute {
    var attr = try findAttribute("type=\"usize\"");
    try std.testing.expectEqualDeep(TAttr{ .name = "type", .value = "usize", .len = 12 }, attr);
    attr = try findAttribute("type=\"isize\"");
    try std.testing.expectEqualDeep(TAttr{ .name = "type", .value = "isize", .len = 12 }, attr);
    attr = try findAttribute("type=\"?usize\"");
    try std.testing.expectEqualDeep(TAttr{ .name = "type", .value = "?usize", .len = 13 }, attr);
    attr = try findAttribute("default=\"text\"");
    try std.testing.expectEqualDeep(TAttr{ .name = "default", .value = "text", .len = 14 }, attr);
    attr = try findAttribute("default=\"text\" />");
    try std.testing.expectEqualDeep(TAttr{ .name = "default", .value = "text", .len = 14 }, attr);
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
    return .{
        .{ .ignore = {} },
        end + 1,
    };
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
    return .{
        .{ .blob = blob[start_ws..end_ws] },
        end,
    };
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
            .blob = trimLeft(u8, self.otherwise.blob, whitespace),
        },
    };
    try p.format("", .{}, out);
}

pub fn withTyped(self: Directive, T: type, block: T, out: anytype) anyerror!void {
    var p = PageRuntime(T){
        .data = block,
        .template = if (self.otherwise == .template) self.otherwise.template.* else .{
            .name = self.noun,
            .blob = trim(u8, self.otherwise.blob, whitespace),
        },
    };
    try p.format("", .{}, out);
}

fn getDynamic(name: []const u8) ?*const Template.Template {
    for (0..dynamic.*.len) |i| {
        if (eql(u8, dynamic.*[i].name, name)) {
            return &dynamic.*[i];
        }
    }
    return null;
}

fn getBuiltin(name: []const u8) ?*const Template.Template {
    for (0..builtin.len) |i| {
        if (eql(u8, builtin[i].name, name)) {
            return &builtin[i];
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
            if (d.known_type) |_| return d.doTyped(T, ctx, out);
            const noun = d.noun;
            const var_name = typeField(T, noun, ctx);
            if (var_name) |data_blob| {
                try out.writeAll(data_blob);
            } else {
                //if (DEBUG) std.debug.print("[missing var {s}]\n", .{noun.vari});
                switch (d.otherwise) {
                    .default => |str| try out.writeAll(str),
                    // Not really an error, just instruct caller to print original text
                    .ignore => return error.IgnoreDirective,
                    .required => return error.VariableMissing,
                    .delete => {},
                    .template => |template| {
                        if (T == usize) unreachable;
                        if (@typeInfo(T) != .Struct) unreachable;
                        inline for (std.meta.fields(T)) |field| {
                            switch (@typeInfo(field.type)) {
                                .Optional => |otype| {
                                    if (otype.child == []const u8) continue;

                                    var local: [0xff]u8 = undefined;
                                    const realname = local[0..makeFieldName(noun[1 .. noun.len - 5], &local)];
                                    if (std.mem.eql(u8, field.name, realname)) {
                                        if (@field(ctx, field.name)) |subdata| {
                                            var subpage = template.pageOf(otype.child, subdata);
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
                                        var subpage = template.pageOf(@TypeOf(subdata), subdata);
                                        try subpage.format("{}", .{}, out);
                                    }
                                },
                                else => {}, //@compileLog(field.type),
                            }
                        }
                    },
                    //inline for (std.meta.fields(T)) |field| {
                    //    if (eql(u8, field.name, noun)) {
                    //        const subdata = @field(ctx, field.name);
                    //        var page = template.pageOf(@TypeOf(subdata), subdata);
                    //        try page.format("{}", .{}, out);
                    //    }
                    //}
                    .blob => unreachable,
                }
            }
        },
        else => d.doTyped(T, ctx, out) catch unreachable,
    }
}
