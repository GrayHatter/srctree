pub const Specifier = enum {
    text,
    target,
    is,
    repo,
    owner,
};

pub const Hit = union(Specifier) {
    text: Data,
    target: Data,
    is: Identity,
    repo: Repo,
    owner: User,

    pub const Repo = Data;
    pub const Identity = Data;
    pub const User = Data;

    pub const Commit = struct {
        sha: git.Sha,
        idx: usize,

        pub fn init(s: git.Sha, idx: usize) Commit {
            return .{ .sha = s, .idx = idx };
        }
    };

    pub const File = struct {
        path: []const u8,
        sha: git.Sha,
        idx: usize,
        line: u32,
        code: []const u8,
    };

    pub const Data = struct {
        _: void,
    };
};

/// By assumption, a subject of len 0 will search across anything
pub const Rule = struct {
    match: Query,
    invert: bool = false,

    pub const Query = union(Specifier) {
        text: []const u8,
        target: struct {
            tag: []const u8,
            text: []const u8,
        },
        is: []const u8, // State,
        repo: []const u8,
        owner: []const u8,

        pub fn format(q: Query, w: *Writer) !void {
            switch (q) {
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

const Exclude = struct {
    list: ArrayList([]const u8),

    pub const new: Exclude = .{ .list = .empty };

    fn excluded(e: *Exclude, path: []const u8) bool {
        for (e.list.items) |ex| {
            if (startsWith(u8, path, ex)) return true;
        }
        return false;
    }

    fn fromSearch(e: *Exclude, str: []const u8, a: Allocator) !void {
        var idx: usize = 0;
        while (idx < str.len) {
            if (findPos(u8, str, idx, "exclude:")) |pos| {
                idx = pos + 1;
                const end = findScalarPos(u8, str, pos, ' ') orelse str.len;
                try e.list.append(a, str[pos + 8 .. end]);
            } else return;
        }
    }

    fn fromRepo(e: *Exclude, repo: *git.Repo, tree: *git.Tree, a: Allocator, io: Io) !void {
        var itr = tree.iterate();
        while (itr.next()) |obj| {
            if (eql(u8, obj.name, ".gitattributes")) {
                switch (repo.objects.load(obj.sha, a, io) catch return error.ServerFault) {
                    .tree, .commit, .tag => break,
                    .blob => |b| {
                        var r: Reader = .fixed(b.data.blob);
                        while (r.takeSentinel('\n')) |line| {
                            if (endsWith(u8, line, "linguist-vendored") or endsWith(u8, line, " binary")) {
                                // Hacky guess instead of actually pattern
                                // matching, (sorry)
                                if (find(u8, line, "/** ")) |idx| {
                                    try e.list.append(a, line[0..idx]);
                                }
                            }
                        } else |_| break;
                    },
                }
            }
        }
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
        fn eval(self: Self, rule: Rule.Query, target: Output) bool {
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

pub fn searchTree(
    files: *ArrayList(Hit.File),
    tree: *git.Tree,
    repo: *git.Repo,
    root: []const u8,
    search_str: []const u8,
    ex: *Exclude,
    limit: *u32,
    a: Allocator,
    io: Io,
) !void {
    var itr = tree.iterate();
    while (itr.next()) |obj| {
        if (limit.* == 0) break;
        const path = if (root.len > 0)
            try a.print("{s}/{s}", .{ root, obj.name })
        else
            obj.name;
        log.debug("searching {s}\n", .{path});
        if (ex.excluded(path)) {
            if (root.len > 0) a.free(path);
            continue;
        }
        limit.* -|= 1;
        var object = try repo.objects.load(obj.sha, a, io);
        switch (object) {
            .tree => |*t| searchTree(files, t, repo, path, search_str, ex, limit, a, io) catch |err| {
                log.err("search error {}", .{err});
                limit.* /= 2;
                continue;
            },
            .blob => |b| {
                if (find(u8, b.data.blob, search_str)) |idx|
                    try files.append(a, .{
                        .path = path,
                        .sha = b.sha,
                        .idx = idx,
                        .line = @truncate(countScalar(u8, b.data.blob[0..idx], '\n')),
                        .code = b.data.blob,
                    });
            },
            .commit, .tag => return error.CorruptedRepo,
        }
    }
}

const extra_lines: usize = 6;

pub fn searchFiles(str: []const u8, repo: *git.Repo, limited: u32, a: Allocator, io: Io) ![]S.SearchHtml.Files {
    var limit: u32 = limited;
    var files: ArrayList(Hit.File) = .empty;
    defer files.deinit(a);
    var commit = try repo.HEAD(a, io);
    var tree: git.Tree = try commit.loadTree(repo, a, io);
    var excludes: Exclude = .new;
    try excludes.fromRepo(repo, &tree, a, io);
    try excludes.fromSearch(str, a);
    defer excludes.list.deinit(a);
    for (excludes.list.items) |ex| log.info("tree exclude {s}", .{ex});
    // TODO real tokenization
    const string = str[0 .. findScalarPos(u8, str, 0, ' ') orelse str.len];
    try searchTree(&files, &tree, repo, "", string, &excludes, &limit, a, io);

    var hits: ArrayList(S.SearchHtml.Files) = try .initCapacity(a, files.items.len);
    for (files.items) |hit| {
        var start: usize = hit.idx;
        var before: usize = extra_lines;
        while (start > 0 and before > 0) : (start -|= 1) {
            if (hit.code[start] == '\n') before -|= 1;
        }
        var end: usize = hit.idx;
        var after: usize = extra_lines;
        while (end < hit.code.len and after > 0) : (end += 1) {
            if (hit.code[end] == '\n') after -|= 1;
        }
        if (start > 0) start += 2;
        const code = hit.code[start .. end - 1];
        var line_number = hit.line + 1 - countScalar(u8, code[0 .. hit.idx - start], '\n');
        var writer: Writer.Allocating = try .initCapacity(a, code.len * 2);
        var source = std.mem.splitScalar(u8, code, '\n');
        while (source.next()) |line| {
            try writer.writer.print("<ln num=\"{}\" id=\"L{}\" href=\"#L{}\">{f}</ln>\n", .{
                line_number, line_number, line_number, abx.Html{ .text = line },
            });
            line_number += 1;
        }
        hits.appendAssumeCapacity(.{
            .filename = .abx(hit.path),
            .line = hit.line + 1,
            .code = .safe(writer.written()),
        });
    }

    return try hits.toOwnedSlice(a);
}

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const findLast = std.mem.findLast;
const find = std.mem.find;
const endsWith = std.mem.endsWith;
const startsWith = std.mem.startsWith;
const cutSuffix = std.mem.cutSuffix;
const eql = std.mem.eql;
const parseInt = std.fmt.parseInt;
const bufPrint = std.fmt.bufPrint;
const log = std.log.scoped(.search);
const git = @import("git.zig");

const findPos = std.mem.findPos;
const findScalarPos = std.mem.findScalarPos;
const countScalar = std.mem.countScalar;

const verse = @import("verse");
const T = verse.template;
const S = T.Structs;
const abx = verse.Antibiotic;
