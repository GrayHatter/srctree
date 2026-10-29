alloc: Allocator,
string: []const u8,
rules: ArrayList(Rule),
repos: ArrayList(Repo),
hits: ArrayList(Hit),

const Search = @This();

pub const Magic = enum {
    is,
    only,
    owner,
    raw,
    repo,
    target,

    pub const Is = enum {
        open,
        closed,
    };

    pub const Only = enum {
        repos,
        commits,
        files,
        deltas,
        issues,
        diffs,
    };
};

pub const Hit = struct {
    result: Result,
    liveness: usize = 0,

    pub const Result = union(Result.Name) {
        commit: Commit,
        delta: Delta,
        file: File,
        repo: Repo,

        pub const Name = enum {
            commit,
            delta,
            file,
            repo,
        };

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
};

pub const Rule = struct {
    rule: Query,
    invert: bool = false,

    pub const Query = union(Magic) {
        is: Magic.Is,
        only: Magic.Only,
        owner: []const u8,
        raw: []const u8,
        repo: []const u8,
        target: struct {
            tag: []const u8,
            text: []const u8,
        },

        pub const empty: Query = .{ .raw = "" };

        pub fn format(q: Query, w: *Writer) !void {
            switch (q) {
                .raw => |s| try w.print("{s}", .{s}),
                .target => |t| try w.print("{s}:{s}", .{ t.tag, t.text }),
                .is => |i| try w.print("is:{s}", .{@tagName(i)}),
                .repo => |rp| try w.print("repo:{s}", .{rp}),
                .owner => |o| try w.print("owner:{s}", .{o}),
                .only => |o| try w.print("only:{s}", .{@tagName(o)}),
            }
        }
    };

    pub const State = enum {
        open,
        closed,
    };

    pub const empty: Rule = .{
        .rule = .empty,
        .invert = false,
    };

    pub fn text(txt: []const u8) Rule {
        return .{
            .rule = .{ .raw = txt },
        };
    }

    pub fn is(str: []const u8, invert: bool) Rule {
        if (eql(u8, str, "open")) {
            return .{ .rule = .{ .is = .open } };
        } else if (eql(u8, str, "closed")) {
            return .{ .rule = .{ .is = .closed } };
        } else return .{
            .rule = .{ .target = .{ .tag = "is", .text = str } },
            .invert = invert,
        };
    }

    pub fn repo(str: []const u8, invert: bool) Rule {
        return .{
            .rule = .{ .repo = str },
            .invert = invert,
        };
    }

    pub fn owner(str: []const u8, invert: bool) Rule {
        return .{
            .rule = .{ .owner = str },
            .invert = invert,
        };
    }

    /// TODO(robinlinden) squote & dquote support
    pub fn parse(str: []const u8) Rule {
        if (str.len < 3) return .empty;
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
                return .{
                    .rule = .{ .target = .{ .tag = pre, .text = match } },
                    .invert = invert,
                };
            }
        } else {
            return .{
                .rule = .{ .raw = s },
                .invert = invert,
            };
        }
    }

    test parse {
        const r0 = parse("");
        try std.testing.expectEqualDeep(Rule.empty, r0);
        const r1 = parse("a");
        try std.testing.expectEqualDeep(Rule.empty, r1);
        const r2 = parse("ab");
        try std.testing.expectEqualDeep(Rule.empty, r2);

        const r3 = parse("abc");
        try std.testing.expectEqualDeep(Rule{ .rule = .{ .raw = "abc" } }, r3);

        const r4 = parse("repo:srctree");
        try std.testing.expectEqualDeep(Rule{ .rule = .{ .repo = "srctree" } }, r4);
        const r5 = parse("repo:verse");
        try std.testing.expectEqualDeep(Rule{ .rule = .{ .repo = "verse" } }, r5);

        const r6 = parse("owner:grayhatter");
        try std.testing.expectEqualDeep(Rule{ .rule = .{ .owner = "grayhatter" } }, r6);

        const r7 = parse("-owner:grayhatter");
        try std.testing.expectEqualDeep(Rule{ .rule = .{ .owner = "grayhatter" }, .invert = true }, r7);
        const r8 = parse("!owner:grayhatter");
        try std.testing.expectEqualDeep(Rule{ .rule = .{ .owner = "grayhatter" }, .invert = true }, r8);

        const r9 = parse("-repo:verse");
        try std.testing.expectEqualDeep(Rule{ .rule = .{ .repo = "verse" }, .invert = true }, r9);
        const r10 = parse("!repo:verse");
        try std.testing.expectEqualDeep(Rule{ .rule = .{ .repo = "verse" }, .invert = true }, r10);
    }

    pub fn format(r: Rule, w: *Writer) !void {
        if (r.invert) try w.writeByte('!');
        try w.print("{f}", .{r.rule});
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

    fn fromRepo(e: *Exclude, git_repo: *git.Repo, tree: *git.Tree, a: Allocator, io: Io) !void {
        var itr = tree.iterate();
        while (itr.next()) |obj| {
            if (eql(u8, obj.name, ".gitattributes")) {
                switch (git_repo.objects.load(obj.sha, a, io) catch return error.ServerFault) {
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

pub fn Iterator(Itr: type) type {
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

        // TODO remove
        pub fn nextDelta(self: *Self, a: Allocator, io: Io) ?Delta {
            while (self.next(a, io)) |nxt| switch (nxt.result) {
                .delta => |d| return d,
                else => continue,
            };
            return null;
        }

        pub fn next(self: *Self, a: Allocator, io: Io) ?Hit {
            const current: Hit = self.iterable.next(a, io) orelse return null;
            if (self.evalRules(current.result)) {
                return current;
            }
            return self.next(a, io);
        }

        fn evalRules(self: Self, target: Hit.Result) bool {
            for (self.rules) |r| {
                if (self.eval(r.rule, target)) {
                    if (r.invert) return false;
                } else if (!r.invert) return false;
            }
            return true;
        }

        /// TODO: I think this function might overrun for some inputs
        /// TODO: add support for int types
        fn eval(self: Self, rule: Rule.Query, target: Hit.Result) bool {
            log.debug("eval rule [{any}]", .{rule});
            switch (rule) {
                .only => |only| switch (only) {
                    .diffs => {
                        log.debug("     rule is diff", .{});
                        if (target != .delta) return false;
                        if (target.delta.attach == .diff) return true;
                        return false;
                    },
                    .issues => {
                        if (target != .delta) return false;
                        log.debug("     rule is issue", .{});
                        if (target.delta.attach == .issue) return true;
                        // TODO better hack
                        if (target.delta.attach == .remote) return true;
                        return false;
                    },
                    .deltas => return true,
                    // TODO
                    .commits => return false,
                    .repos => return false,
                    .files => return false,
                },
                .is => |is| switch (is) {
                    .open => return target.delta.state.isOpen(),
                    .closed => return target.delta.state.closed,
                },
                .repo => |trepo| switch (target) {
                    .repo => return eql(u8, target.repo.name orelse return false, trepo),
                    .delta => return eql(u8, target.delta.repo, trepo),
                    else => return false,
                },
                .target => |trgt| inline for (comptime std.meta.fieldNames(Hit.Result)) |name| {
                    if (eql(u8, trgt.tag, name)) {
                        if (@TypeOf(@field(target, name)) == []const u8) {
                            if (find(u8, @field(target, name), trgt.text)) |_| {
                                return true;
                            }
                        }
                    }
                } else return false,
                .raw => |any| inline for (comptime std.meta.fieldNames(Hit.Result)) |name| {
                    if (@TypeOf(@field(target, name)) == []const u8) {
                        if (find(u8, @field(target, name), any)) |_| {
                            return true;
                        }
                    }
                } else return false,
                .owner => |owner| if (@hasField(Hit.Result, "owner")) {
                    log.debug("     rule owner '{s}' '{s}'", .{ owner, self.data.user });
                    if (eql(u8, owner, "me") and eql(u8, self.data.user, target.owner))
                        return true
                    else
                        return eql(u8, self.data.user, target.owner);
                } else {
                    log.debug("     " ++ @typeName(Hit.Result) ++ " has no owner [default true]", .{});
                    return true;
                },
            }
        }

        pub fn raze(_: Self) void {
            comptime unreachable;
        }
    };
}

pub fn RepoDeltaIterator(Indexer: type) type {
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

        pub fn next(self: *Self, a: Allocator, io: Io) ?Hit {
            while (self.index > 0) {
                defer self.index -|= 1;
                return .{ .result = .{
                    .delta = Delta.open(self.repo, self.index, a, io) catch continue,
                } };
            }
            return null;
        }
    };
}

pub fn init(str: []const u8, a: Allocator) !Search {
    var rules: ArrayList(Rule) = .empty;
    var itr = splitScalar(u8, str, ' ');
    while (itr.next()) |r_line| {
        var line = r_line;
        line = trim(u8, line, " ");
        if (line.len == 0) continue;
        try rules.append(a, .parse(line));
    }
    return .{
        .alloc = a,
        .string = str,
        .rules = rules,
        .repos = .empty,
        .hits = .empty,
    };
}

pub fn raze(search: *Search) void {
    search.repos.deinit(search.alloc);
    search.rules.deinit(search.alloc);
    search.hits.deinit(search.alloc);
}

pub fn reposFor(rules: *const Search) ![]S.SearchHtml.SearchResults {
    _ = rules;
    return &.{};
}

pub fn searchTree(
    search: *Search,
    tree: *git.Tree,
    repo: *git.Repo,
    root: []const u8,
    search_str: []const u8,
    ex: *Exclude,
    limit: *u32,
    io: Io,
) !void {
    var itr = tree.iterate();
    while (itr.next()) |obj| {
        if (limit.* == 0) break;
        const path = if (root.len > 0)
            try search.alloc.print("{s}/{s}", .{ root, obj.name })
        else
            obj.name;
        log.debug("searching {s}\n", .{path});
        if (ex.excluded(path)) {
            if (root.len > 0) search.alloc.free(path);
            continue;
        }
        limit.* -|= 1;
        var object = try repo.objects.load(obj.sha, search.alloc, io);
        switch (object) {
            .tree => |*t| search.searchTree(t, repo, path, search_str, ex, limit, io) catch |err| {
                log.err("search error {}", .{err});
                limit.* /= 2;
                continue;
            },
            .blob => |b| {
                if (find(u8, b.data.blob, search_str)) |idx|
                    try search.appendHit(.{ .result = .{ .file = .{
                        .path = path,
                        .sha = b.sha,
                        .idx = idx,
                        .line = @truncate(countScalar(u8, b.data.blob[0..idx], '\n')),
                        .code = b.data.blob,
                    } } });
            },
            .commit, .tag => return error.CorruptedRepo,
        }
    }
}

fn appendHit(search: *Search, hit: Hit) !void {
    try search.hits.append(search.alloc, hit);
}

const extra_lines: usize = 6;

pub fn files(
    search: *Search,
    repo: *Repo,
    io: Io,
    search_limit: u32,
) ![]S.SearchFlavor.File {
    var limit: u32 = search_limit;
    var file_list: ArrayList(Hit.Result.File) = .empty;
    defer file_list.deinit(search.alloc);
    var commit = try repo.git.HEAD(search.alloc, io);
    var tree: git.Tree = try commit.loadTree(&repo.git, search.alloc, io);
    var excludes: Exclude = .new;
    try excludes.fromRepo(&repo.git, &tree, search.alloc, io);
    try excludes.fromSearch(search.string, search.alloc);
    defer excludes.list.deinit(search.alloc);
    for (excludes.list.items) |ex| log.info("tree exclude {s}", .{ex});
    // TODO real tokenization
    const string = search.string[0 .. findScalarPos(u8, search.string, 0, ' ') orelse search.string.len];
    try search.searchTree(&tree, &repo.git, "", string, &excludes, &limit, io);

    var hits: ArrayList(S.SearchFlavor.File) = try .initCapacity(search.alloc, file_list.items.len);
    for (file_list.items) |hit| {
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
        var writer: Writer.Allocating = try .initCapacity(search.alloc, code.len * 2);
        var source = std.mem.splitScalar(u8, code, '\n');
        while (source.next()) |line| {
            try writer.writer.print("<ln num=\"{}\" id=\"L{}\" href=\"#L{}\">{f}</ln>\n", .{
                line_number, line_number, line_number, abx.Html{ .text = line },
            });
            line_number += 1;
        }
        hits.appendAssumeCapacity(.{
            .repo_name = .safe(repo.name orelse ""),
            .filename = .abx(hit.path),
            .line = hit.line + 1,
            .code = .safe(writer.written()),
        });
    }

    return try hits.toOwnedSlice(search.alloc);
}

test Search {
    _ = &std.testing.refAllDecls(Search);

    var search: Search = try .init("repo:srctree owner:grayhatter verse", std.testing.allocator);
    defer search.raze();

    try std.testing.expectEqualDeep(Search{
        .alloc = std.testing.allocator,
        .string = "repo:srctree owner:grayhatter verse",
        .rules = .{
            .items = @constCast(&[_]Rule{
                .{ .rule = .{ .repo = "srctree" } },
                .{ .rule = .{ .owner = "grayhatter" } },
                .{ .rule = .{ .raw = "verse" } },
            }),
            .capacity = 3,
            .pointer_stability = .{},
        },
        .repos = .empty,
        .hits = .empty,
    }, search);

    search.raze();
    search = try .init("srctree", std.testing.allocator);
    try std.testing.expectEqualDeep(Search{
        .alloc = std.testing.allocator,
        .string = "srctree",
        .rules = .{
            .items = @constCast(&[_]Rule{
                .{ .rule = .{ .raw = "srctree" } },
            }),
            .capacity = 3,
            .pointer_stability = .{},
        },
        .repos = .empty,
        .hits = .empty,
    }, search);
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
const splitScalar = std.mem.splitScalar;
const parseInt = std.fmt.parseInt;
const bufPrint = std.fmt.bufPrint;
const cutPrefix = std.mem.cutPrefix;
const trim = std.mem.trim;
const eql = std.mem.eql;
const findScalar = std.mem.findScalar;

const log = std.log.scoped(.search);
const git = @import("git.zig");
const Repo = @import("Repo.zig");
const Delta = @import("types.zig").Delta;

const findPos = std.mem.findPos;
const findScalarPos = std.mem.findScalarPos;
const countScalar = std.mem.countScalar;

const verse = @import("verse");
const T = verse.template;
const S = T.Structs;
const abx = verse.Antibiotic;
