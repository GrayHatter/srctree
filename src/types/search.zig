pub const Specifier = enum {
    search,
    target,
    is,
    repo,
};

/// By assumption, a subject of len 0 will search across anything
pub const Rule = union(Specifier) {
    search: String,
    target: struct { tag: []const u8, string: String },
    is: String,
    repo: String,

    pub const String = struct {
        match: []const u8,
        inverse: bool = false,
    };

    pub fn parse(str: []const u8) Rule {
        if (str.len < 2) return .{ .search = .{ .match = &.{}, .inverse = false } };
        var s = str;
        const inverse = str[0] == '-';
        if (inverse) s = s[1..];

        if (indexOf(u8, s, ":")) |i| {
            if (i == 0) return .{ .search = .{ .match = s, .inverse = inverse } };

            const string: String = .{ .match = s[i + 1 ..], .inverse = inverse };

            const pre: []const u8 = s[0..i];
            if (eql(u8, pre, "is")) {
                return .{ .is = string };
            } else if (eql(u8, pre, "repo")) {
                return .{ .repo = string };
            } else {
                return .{ .target = .{ .tag = pre, .string = string } };
            }
        } else {
            const string: String = .{ .match = s, .inverse = inverse };
            return .{ .search = string };
        }
    }

    pub fn format(rule: Rule, w: *Writer) !void {
        switch (rule) {
            .search => |s| try w.print("{s}{s}", .{ if (s.inverse) "!" else "", s.match }),
            .target => |t| try w.print("{s}{s}:{s}", .{ if (t.string.inverse) "!" else "", t.tag, t.string.match }),
            .is => |i| try w.print("{s}is:{s}", .{ if (i.inverse) "!" else "", i.match }),
            .repo => |r| try w.print("{s}repo:{s}", .{ if (r.inverse) "!" else "", r.match }),
        }
    }
};

pub fn Iterator(Itr: type, Output: type) type {
    return struct {
        rules: []const Rule,

        // TODO better ABI
        iterable: Itr,

        const Self = @This();

        pub fn next(self: *Self, a: Allocator, io: Io) ?Output {
            const current = self.iterable.next(a, io) orelse return null;
            if (self.evalRules(current)) {
                return current;
            }
            return self.next(a, io);
        }

        fn evalRules(self: Self, target: Output) bool {
            for (self.rules) |rule| {
                if (!self.eval(rule, target)) return false;
            } else return true;
        }

        /// TODO: I think this function might overrun for some inputs
        /// TODO: add support for int types
        fn eval(_: Self, rule: Rule, target: Output) bool {
            if (comptime std.meta.hasMethod(Output, "searchEval")) {
                return target.searchEval(rule);
            }

            switch (rule) {
                .is => |is| {
                    if (eql(u8, is.match, "diff")) {
                        if (target.attach == .diff) return true;
                    } else if (eql(u8, is.match, "issue")) {
                        if (target.attach == .issue) return true;
                        // TODO better hack
                        if (target.attach == .remote) return true;
                    } else if (eql(u8, is.match, "open")) {
                        return !target.state.closed;
                    } else if (eql(u8, is.match, "closed")) {
                        return target.state.closed;
                    } else {
                        if (target.attach == .nos) return true;
                    }
                    return false;
                },
                .repo => |repo| return eql(u8, repo.match, target.repo),
                .target => |trgt| {
                    inline for (comptime std.meta.fieldNames(Output)) |name| {
                        if (eql(u8, trgt.tag, name)) {
                            if (@TypeOf(@field(target, name)) == []const u8) {
                                if (indexOf(u8, @field(target, name), trgt.string.match)) |_| {
                                    return true;
                                }
                            }
                        }
                    }
                    return false;
                },
                .search => |any| {
                    inline for (comptime std.meta.fieldNames(Output)) |name| {
                        if (@TypeOf(@field(target, name)) == []const u8) {
                            if (indexOf(u8, @field(target, name), any.match)) |_| {
                                return true;
                            }
                        }
                    }
                    return false;
                },
            }
        }

        pub fn raze(_: Self) void {}
    };
}

pub fn RepoIterator(Indexer: type, Output: type) type {
    return struct {
        index: usize = 0,
        repo: []const u8,

        pub const Self = @This();
        pub const Index = Indexer;

        pub fn init(repo: []const u8, io: Io) Self {
            return .{
                .repo = repo,
                .index = Index.currentExtra(repo, io) catch 0,
            };
        }

        pub fn next(self: *Self, a: Allocator, io: Io) ?Output {
            while (self.index > 0) {
                defer self.index -|= 1;
                return Output.open(self.repo, self.index, a, io) catch continue;
            }
            return null;
        }
    };
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const Io = std.Io;
const Writer = Io.Writer;
const lastIndexOf = std.mem.lastIndexOf;
const indexOf = std.mem.indexOf;
const endsWith = std.mem.endsWith;
const cutSuffix = std.mem.cutSuffix;
const eql = std.mem.eql;
const parseInt = std.fmt.parseInt;
const bufPrint = std.fmt.bufPrint;
const endian = builtin.cpu.arch.endian();
