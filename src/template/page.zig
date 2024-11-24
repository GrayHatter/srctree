const std = @import("std");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

const Templates = @import("../template.zig");
const Template = Templates.Template;
const DataMap = Templates.DataMap;
const Directive = Templates.Directive;

const makeStructName = Templates.makeStructName;
const makeFieldName = Templates.makeFieldName;

const findTemplate = Templates.findTemplate;

const DEBUG = false;

pub fn PageRuntime(comptime PageDataType: type) type {
    return struct {
        pub const Self = @This();
        pub const Kind = PageDataType;
        template: Template,
        data: PageDataType,

        pub fn init(t: Template, d: PageDataType) PageRuntime(PageDataType) {
            return .{
                .template = t,
                .data = d,
            };
        }

        pub fn byName(comptime name: []const u8, d: DataMap) Page {
            return .{
                .template = findTemplate(name),
                .data = d,
            };
        }

        pub fn build(self: Self, a: Allocator) ![]u8 {
            return std.fmt.allocPrint(a, "{}", .{self});
        }

        fn typeField(name: []const u8, data: PageDataType) ?[]const u8 {
            var local: [0xff]u8 = undefined;
            const realname = local[0..makeFieldName(name, &local)];
            inline for (std.meta.fields(PageDataType)) |field| {
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

        fn formatAny(
            self: Self,
            comptime fmts: []const u8,
            ctx: *DataMap,
            drct: Directive,
            out: anytype,
        ) anyerror!void {
            switch (drct.verb) {
                .variable => {
                    const noun = drct.noun;
                    const var_name = ctx.get(noun);
                    if (var_name) |v_blob| {
                        switch (v_blob) {
                            .slice => |s_blob| try out.writeAll(s_blob),
                            .block => |_| unreachable,
                            .reader => |_| unreachable,
                        }
                    } else {
                        if (DEBUG) std.debug.print("[missing var {s}]\n", .{noun});
                        switch (drct.otherwise) {
                            .str => |str| try out.writeAll(str),
                            // Not really an error, just instruct caller to print original text
                            .ign => return error.IgnoreDirective,
                            .del => {},
                            .template => |subt| {
                                var subpage = subt.page(self.data);
                                subpage.format(fmts, .{}, out) catch |err| {
                                    std.debug.print("swallowed subpage format error {}\n", .{err});
                                    unreachable;
                                };
                            },
                            .blob => unreachable,
                        }
                    }
                },
                else => drct.do(ctx, out) catch unreachable,
            }
        }

        fn formatTyped(
            self: Self,
            comptime fmts: []const u8,
            ctx: PageDataType,
            drct: Directive,
            out: anytype,
        ) anyerror!void {
            switch (drct.verb) {
                .variable => {
                    const noun = drct.noun;
                    const var_name = typeField(noun, ctx);
                    if (var_name) |data_blob| {
                        try out.writeAll(data_blob);
                    } else {
                        if (DEBUG) std.debug.print("[missing var {s}]\n", .{noun.vari});
                        switch (drct.otherwise) {
                            .str => |str| try out.writeAll(str),
                            // Not really an error, just instruct caller to print original text
                            .ign => return error.IgnoreDirective,
                            .del => {},
                            .template => |subt| {
                                inline for (std.meta.fields(PageDataType)) |field|
                                    switch (@typeInfo(field.type)) {
                                        .Optional => |otype| {
                                            if (otype.child == []const u8) continue;

                                            var local: [0xff]u8 = undefined;
                                            const realname = local[0..makeFieldName(noun[1 .. noun.len - 5], &local)];
                                            if (std.mem.eql(u8, field.name, realname)) {
                                                if (@field(self.data, field.name)) |subdata| {
                                                    var subpage = subt.pageOf(otype.child, subdata);
                                                    try subpage.format(fmts, .{}, out);
                                                } else std.debug.print(
                                                    "sub template data was null for {s}\n",
                                                    .{field.name},
                                                );
                                            }
                                        },
                                        .Struct => {
                                            if (std.mem.eql(u8, field.name, noun)) {
                                                const subdata = @field(self.data, field.name);
                                                var subpage = subt.pageOf(@TypeOf(subdata), subdata);
                                                try subpage.format(fmts, .{}, out);
                                            }
                                        },
                                        else => {}, //@compileLog(field.type),
                                    };
                            },
                            .blob => unreachable,
                        }
                    }
                },
                else => drct.doTyped(PageDataType, ctx, out) catch unreachable,
            }
        }
        pub fn format(self: Self, comptime fmts: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
            var ctx = self.data;
            var blob = self.template.blob;
            while (blob.len > 0) {
                if (std.mem.indexOf(u8, blob, "<")) |offset| {
                    try out.writeAll(blob[0..offset]);
                    blob = blob[offset..];
                    if (Directive.init(blob)) |drct| {
                        const end = drct.end;
                        if (comptime PageDataType == DataMap) {
                            self.formatAny(fmts, &ctx, drct, out) catch |err| switch (err) {
                                error.IgnoreDirective => try out.writeAll(blob[0..end]),
                                else => return err,
                            };
                        } else {
                            self.formatTyped(fmts, ctx, drct, out) catch |err| switch (err) {
                                error.IgnoreDirective => try out.writeAll(blob[0..end]),
                                else => return err,
                            };
                        }
                        blob = blob[end..];
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
}

pub fn Page(comptime template: Template, comptime PageDataType: type) type {
    return struct {
        pub const Self = @This();
        pub const Kind = PageDataType;
        pub const PageTemplate = template;
        data: PageDataType,

        pub fn init(d: PageDataType) Page(template, PageDataType) {
            return .{ .data = d };
        }

        pub fn build(self: Self, a: Allocator) ![]u8 {
            return std.fmt.allocPrint(a, "{}", .{self});
        }

        fn typeField(name: []const u8, data: PageDataType) ?[]const u8 {
            var local: [0xff]u8 = undefined;
            const realname = local[0..makeFieldName(name, &local)];
            inline for (std.meta.fields(PageDataType)) |field| {
                if (std.mem.eql(u8, field.name, realname)) {
                    switch (field.type) {
                        []const u8, ?[]const u8 => return @field(data, field.name),
                        else => return null,
                    }
                }
            }
            return null;
        }

        fn formatAny(
            self: Self,
            comptime fmts: []const u8,
            ctx: *DataMap,
            drct: Directive,
            out: anytype,
        ) anyerror!void {
            switch (drct.verb) {
                .variable => {
                    const noun = drct.noun;
                    const var_name = ctx.get(noun);
                    if (var_name) |v_blob| {
                        switch (v_blob) {
                            .slice => |s_blob| try out.writeAll(s_blob),
                            .block => |_| unreachable,
                            .reader => |_| unreachable,
                        }
                    } else {
                        if (DEBUG) std.debug.print("[missing var {s}]\n", .{noun.vari});
                        switch (drct.otherwise) {
                            .str => |str| try out.writeAll(str),
                            // Not really an error, just instruct caller to print original text
                            .ign => return error.IgnoreDirective,
                            .del => {},
                            .template => |subt| {
                                var subpage = subt.page(self.data);
                                subpage.format(fmts, .{}, out) catch |err| {
                                    std.debug.print("swallowed subpage format error {}\n", .{err});
                                    unreachable;
                                };
                            },
                            .blob => unreachable,
                        }
                    }
                },
                else => drct.do(ctx, out) catch unreachable,
            }
        }

        fn formatTyped(
            self: Self,
            comptime fmts: []const u8,
            ctx: PageDataType,
            drct: Directive,
            out: anytype,
        ) anyerror!void {
            switch (drct.verb) {
                .variable => {
                    const noun = drct.noun;
                    const var_name = typeField(noun, ctx);
                    if (var_name) |data_blob| {
                        try out.writeAll(data_blob);
                    } else {
                        if (DEBUG) std.debug.print("[missing var {s}]\n", .{noun});
                        switch (drct.otherwise) {
                            .str => |str| try out.writeAll(str),
                            // Not really an error, just instruct caller to print original text
                            .ign => return error.IgnoreDirective,
                            .del => {},
                            .template => |subt| {
                                inline for (std.meta.fields(PageDataType)) |field|
                                    switch (@typeInfo(field.type)) {
                                        .Optional => |otype| {
                                            if (otype.child == []const u8) continue;

                                            var local: [0xff]u8 = undefined;
                                            const realname = local[0..makeFieldName(noun[1 .. noun.len - 5], &local)];
                                            if (eql(u8, field.name, realname)) {
                                                if (@field(self.data, field.name)) |subdata| {
                                                    var subpage = subt.pageOf(otype.child, subdata);
                                                    try subpage.format(fmts, .{}, out);
                                                } else std.debug.print(
                                                    "sub template data was null for {s}\n",
                                                    .{field.name},
                                                );
                                            }
                                        },
                                        .Struct => {
                                            if (eql(u8, field.name, noun)) {
                                                const subdata = @field(self.data, field.name);
                                                var subpage = subt.pageOf(@TypeOf(subdata), subdata);
                                                try subpage.format(fmts, .{}, out);
                                            }
                                        },
                                        else => {}, //@compileLog(field.type),
                                    };
                            },
                            .blob => unreachable,
                        }
                    }
                },
                .typed,
                .foreach,
                .forrow,
                .with,
                .build,
                => drct.doTyped(PageDataType, ctx, out) catch unreachable,
            }
        }

        pub fn format(self: Self, comptime fmts: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
            const ctx = self.data;
            var blob = Self.PageTemplate.blob;
            while (blob.len > 0) {
                if (std.mem.indexOf(u8, blob, "<")) |offset| {
                    try out.writeAll(blob[0..offset]);
                    blob = blob[offset..];
                    if (Directive.init(blob)) |drct| {
                        const end = drct.end;
                        //if (comptime Self.Live) {
                        //    self.formatAny(fmts, &ctx, drct, out) catch |err| switch (err) {
                        //        error.IgnoreDirective => try out.writeAll(blob[0..end]),
                        //        else => return err,
                        //    };
                        //} else {
                        self.formatTyped(fmts, ctx, drct, out) catch |err| switch (err) {
                            error.IgnoreDirective => try out.writeAll(blob[0..end]),
                            else => return err,
                        };
                        //}
                        blob = blob[end..];
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
}
