const std = @import("std");
const is_test = @import("builtin").is_test;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

const Templates = @import("../template.zig");
const Template = Templates.Template;
const Directive = Templates.Directive;

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

        pub fn build(self: Self, a: Allocator) ![]u8 {
            return std.fmt.allocPrint(a, "{}", .{self});
        }

        pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
            //var ctx = self.data;
            var blob = self.template.blob;
            while (blob.len > 0) {
                if (std.mem.indexOf(u8, blob, "<")) |offset| {
                    try out.writeAll(blob[0..offset]);
                    blob = blob[offset..];
                    if (Directive.init(blob)) |drct| {
                        const end = drct.tag_block.len;
                        drct.formatTyped(PageDataType, self.data, out) catch |err| switch (err) {
                            error.IgnoreDirective => try out.writeAll(blob[0..end]),
                            error.VariableMissing => {
                                if (!is_test) std.debug.print("Template Error, variable missing {{{s}}}\n", .{blob[0..end]});
                                try out.writeAll(blob[0..end]);
                            },
                            else => return err,
                        };

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

        pub fn format(self: Self, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
            var blob = Self.PageTemplate.blob;
            while (blob.len > 0) {
                if (std.mem.indexOf(u8, blob, "<")) |offset| {
                    try out.writeAll(blob[0..offset]);
                    blob = blob[offset..];

                    if (Directive.init(blob)) |drct| {
                        const end = drct.tag_block.len;
                        drct.formatTyped(PageDataType, self.data, out) catch |err| switch (err) {
                            error.IgnoreDirective => try out.writeAll(blob[0..end]),
                            error.VariableMissing => {
                                if (!is_test) std.debug.print("Template Error, variable missing {{{s}}}\n", .{blob[0..end]});
                                try out.writeAll(blob[0..end]);
                            },
                            else => return err,
                        };

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
