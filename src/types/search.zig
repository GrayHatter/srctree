pub const Specifier = enum {
    text,
    target,
    is,
    repo,
    owner,
};

/// By assumption, a subject of len 0 will search across anything
pub const Rule = struct {
    match: Match,
    invert: bool = false,

    pub const Match = union(Specifier) {
        text: []const u8,
        target: struct {
            tag: []const u8,
            text: []const u8,
        },
        is: []const u8, // State,
        repo: []const u8,
        owner: []const u8,

        pub fn format(m: Match, w: *Writer) !void {
            switch (m) {
                .text => |s| try w.print("{s}", .{s}),
                .target => |t| try w.print("{s}:{s}", .{ t.tag, t.text }),
                .is => |i| try w.print("is:{s}", .{i}),
                .repo => |rp| try w.print("repo:{s}", .{rp}),
                .owner => |o| try w.print("owner:{s}", .{o}),
            }
        }
    };

    pub const State = enum {
        open,
        closed,
    };

    pub const empty: Rule = .{
        .match = .{ .text = "" },
        .invert = false,
    };

    pub fn text(txt: []const u8) Rule {
        return .{ .match = .{ .text = txt } };
    }

    pub fn is(str: []const u8, invert: bool) Rule {
        return .{ .match = .{ .is = str }, .invert = invert };
    }

    pub fn repo(str: []const u8, invert: bool) Rule {
        return .{ .match = .{ .repo = str }, .invert = invert };
    }

    pub fn owner(str: []const u8, invert: bool) Rule {
        return .{ .match = .{ .owner = str }, .invert = invert };
    }

    /// TODO(robinlinden) squote & dquote support
    pub fn parse(str: []const u8) Rule {
        if (str.len < 2) return .empty;
        var s = str;
        const invert = str[0] == '-' or str[0] == '!';
        if (invert) s = s[1..];

        if (find(u8, s, ":")) |i| {
            if (i == 0) return .text(s);
            const match = s[i + 1 ..];
            const pre: []const u8 = s[0..i];
            if (eql(u8, pre, "is")) {
                return .is(match, invert);
            } else if (eql(u8, pre, "repo")) {
                return .repo(match, invert);
            } else if (eql(u8, pre, "owner")) {
                return .owner(match, invert);
            } else {
                return .{ .match = .{ .target = .{ .tag = pre, .text = match } }, .invert = invert };
            }
        } else return .{ .match = .{ .text = s }, .invert = invert };
    }

    pub fn format(r: Rule, w: *Writer) !void {
        if (r.invert) try w.writeByte('!');
        try w.print("{f}", .{r.match});
    }
};

pub fn Iterator(Itr: type, Output: type) type {
    return struct {
        rules: []const Rule,
        // TODO better ABI
        iterable: Itr,
        data: Data = .empty,

        pub const Data = struct {
            user: []const u8,

            pub const empty: Data = .{
                .user = &.{},
            };
        };

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
                if (self.eval(rule.match, target)) {
                    if (rule.invert) return false;
                } else if (!rule.invert) return false;
            }
            return true;
        }

        /// TODO: I think this function might overrun for some inputs
        /// TODO: add support for int types
        fn eval(self: Self, rule: Rule.Match, target: Output) bool {
            log.debug("eval rule [{any}]", .{rule});
            if (comptime std.meta.hasMethod(Output, "searchEval")) {
                return target.searchEval(rule);
            }

            switch (rule) {
                .is => |is| if (eql(u8, is, "diff")) {
                    log.debug("     rule is diff", .{});
                    if (target.attach == .diff) return true;
                    return false;
                } else if (eql(u8, is, "issue")) {
                    log.debug("     rule is issue", .{});
                    if (target.attach == .issue) return true;
                    // TODO better hack
                    if (target.attach == .remote) return true;
                    return false;
                } else if (eql(u8, is, "open")) {
                    log.debug("     rule open {}", .{target.state.isOpen()});
                    return target.state.isOpen();
                } else if (eql(u8, is, "closed")) {
                    return target.state.closed;
                } else if (eql(u8, is, "draft")) {
                    return target.state.draft;
                } else {
                    if (target.attach == .nos) return true;
                    return false;
                },
                .repo => |repo| return eql(u8, target.repo, repo),
                .target => |trgt| inline for (comptime std.meta.fieldNames(Output)) |name| {
                    if (eql(u8, trgt.tag, name)) {
                        if (@TypeOf(@field(target, name)) == []const u8) {
                            if (find(u8, @field(target, name), trgt.text)) |_| {
                                return true;
                            }
                        }
                    }
                } else return false,
                .text => |any| inline for (comptime std.meta.fieldNames(Output)) |name| {
                    if (@TypeOf(@field(target, name)) == []const u8) {
                        if (find(u8, @field(target, name), any)) |_| {
                            return true;
                        }
                    }
                } else return false,
                .owner => |owner| if (@hasField(Output, "owner")) {
                    log.debug("     rule owner '{s}' '{s}'", .{ owner, self.data.user });
                    if (eql(u8, owner, "me") and eql(u8, self.data.user, target.owner))
                        return true
                    else
                        return eql(u8, self.data.user, target.owner);
                } else {
                    log.debug("     " ++ @typeName(Output) ++ " has no owner [default true]", .{});
                    return true;
                },
            }
        }

        pub fn raze(_: Self) void {
            comptime unreachable;
        }
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
                .index = Index.scoped.current(repo, io) catch 0,
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
const findLast = std.mem.findLast;
const find = std.mem.find;
const endsWith = std.mem.endsWith;
const cutSuffix = std.mem.cutSuffix;
const eql = std.mem.eql;
const parseInt = std.fmt.parseInt;
const bufPrint = std.fmt.bufPrint;
const endian = builtin.cpu.arch.endian();
const log = std.log.scoped(.types_search);
