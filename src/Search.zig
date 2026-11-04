alloc: Allocator,
depth: Depth,
string: []const u8,
rules: ArrayList(Rule),
full_term_count: usize = 0,
repos: ArrayList(Repo),
hits: ArrayList(Hit),
excluded: Exclude = .empty,
// Unstable API
only: ?Magic.Only,
repo: ?*Repo,
meta: struct {
    checked: usize = 0,
    repos: HashMap(usize) = .empty,
    deltas: HashMap(usize) = .empty,
    commits: HashMap(usize) = .empty,
    files: HashMap(usize) = .empty,

    const HashMap = std.hash_map.StringHashMapUnmanaged;
} = .{},

const Search = @This();

pub const Depth = enum { quick, deep };

pub const Magic = enum {
    is,
    kind,
    only,
    owner,
    raw,
    repo,
    target,

    pub const Is = enum {
        open,
        closed,
    };

    pub const Kind = enum {
        commits,
        deltas,
        diffs,
        files,
        issues,
        repos,
        filenames,
    };

    pub const Only = Kind;
};

pub const Hit = struct {
    result: Result,
    liveness: Liveness = .zero,

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
            repo_name: []const u8,
            sha: git.Sha.Text,
            title: []const u8,
            body: []const u8 = &.{},

            pub fn init(c: *const git.Commit, repo_name: []const u8) Commit {
                return .{
                    .repo_name = repo_name,
                    .sha = c.sha.text(),
                    .title = c.title,
                    .body = c.body,
                };
            }
        };

        pub const File = struct {
            repo_name: []const u8,
            path: []const u8,
            sha: git.Sha.Text,
            hit_idx: usize,
            line: u32,
            line_count: u32,
            code: []const u8,
        };
    };

    /// Liveness assumes the power curve (80/20) represents the importance of a search
    /// hit. Creation = 1000, interaction = 200, views = 10, anonviews = 1
    pub const Liveness = enum(isize) {
        min = std.math.minInt(isize),
        zero = 0,
        any_view = 1,
        user_view = 10,
        engagement = 200,
        created = 1000,
        max = std.math.maxInt(isize),
        _,

        pub fn add(lv: *Liveness, new: Liveness) void {
            lv.* = @fromBackingInt(@backingInt(lv.*) +| @backingInt(new));
        }

        pub fn sub(lv: *Liveness, new: Liveness) void {
            lv.* = @fromBackingInt(@backingInt(lv.*) -| @backingInt(new));
        }
    };
};

pub const Rule = struct {
    rule: Query,
    invert: bool = false,

    pub const Query = union(Magic) {
        is: Magic.Is,
        kind: Magic.Kind,
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
                .is => |i| try w.print("is:{s}", .{@tagName(i)}),
                .kind => |k| try w.print("kind:{s}", .{@tagName(k)}),
                .only => |o| try w.print("only:{s}", .{@tagName(o)}),
                .owner => |o| try w.print("owner:{s}", .{o}),
                .raw => |s| try w.print("{s}", .{s}),
                .repo => |rp| try w.print("repo:{s}", .{rp}),
                .target => |t| try w.print("[{s}]:{s}", .{ t.tag, t.text }),
            }
        }
    };

    pub const empty: Rule = .{
        .rule = .empty,
        .invert = false,
    };

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

    pub fn kind(str: []const u8, inv: bool) Rule {
        const E = @typeInfo(Magic.Kind).@"enum";
        inline for (E.field_names, E.field_values) |name, val| {
            if (startsWith(u8, name, str)) return .{
                .rule = .{ .kind = @fromBackingInt(val) },
                .invert = inv,
            };
        } else return .text(str, inv);
    }

    pub fn only(str: []const u8, inv: bool) Rule {
        const E = @typeInfo(Magic.Only).@"enum";
        inline for (E.field_names, E.field_values) |name, val| {
            if (startsWith(u8, name, str)) return .{
                .rule = .{ .only = @fromBackingInt(val) },
                .invert = inv,
            };
        } else return .text(str, inv);
    }

    pub fn owner(str: []const u8, inv: bool) Rule {
        return .{ .rule = .{ .owner = str }, .invert = inv };
    }

    // raw
    pub fn text(txt: []const u8, inv: bool) Rule {
        return .{ .rule = .{ .raw = txt }, .invert = inv };
    }

    pub fn repo(str: []const u8, inv: bool) Rule {
        return .{ .rule = .{ .repo = str }, .invert = inv };
    }

    //pub const ValidOpen = enum(u8) {
    //    squote = '\'',
    //    dquote = '"',
    //    bracket = '[',
    //    parenth = '(',
    //    angle = '<',
    //    curly = '{',
    //};

    fn open(in: u8) u8 {
        return switch (in) {
            '\'' => '\'',
            '"' => '"',
            '[' => ']',
            '(' => ')',
            '<' => '>',
            '{' => '}',
            else => ' ',
            // TODO extra review
            ' ' => 0,
        };
    }

    fn parseFromOpen(str: []const u8) []const u8 {
        if (str.len < 4) return str;
        const chr = open(str[0]);
        const end = findScalarPos(u8, str, 1, chr) orelse return str;

        return if (chr == ' ') str[0..end] else str[1..end];
    }

    test parseFromOpen {
        try std.testing.expectEqualStrings("", parseFromOpen(""));
        try std.testing.expectEqualStrings("1", parseFromOpen("1"));
        try std.testing.expectEqualStrings("12", parseFromOpen("12"));
        try std.testing.expectEqualStrings("'1'", parseFromOpen("'1'"));
        try std.testing.expectEqualStrings("word", parseFromOpen("\"word\""));
        try std.testing.expectEqualStrings("word", parseFromOpen("'word'"));
        try std.testing.expectEqualStrings("word", parseFromOpen("[word]"));
        try std.testing.expectEqualStrings("word word", parseFromOpen("[word word]"));
        try std.testing.expectEqualStrings("word", parseFromOpen("{word}"));
        try std.testing.expectEqualStrings("word word2", parseFromOpen("{word word2}"));
        try std.testing.expectEqualStrings("word", parseFromOpen("<word>"));
        try std.testing.expectEqualStrings("word word3", parseFromOpen("<word word3>"));
        try std.testing.expectEqualStrings("word ", parseFromOpen("(word )"));
        try std.testing.expectEqualStrings("wordword word 4", parseFromOpen("(wordword word 4)"));

        try std.testing.expectEqualStrings("first", parseFromOpen("first second third forth)"));
        try std.testing.expectEqualStrings(" second third forth)", parseFromOpen(" second third forth)"));
        try std.testing.expectEqualStrings("second", parseFromOpen("second third forth)"));
        try std.testing.expectEqualStrings("third", parseFromOpen("third forth)"));
        try std.testing.expectEqualStrings("forth)", parseFromOpen("forth)"));

        try std.testing.expectEqualStrings(" first second third forth", parseFromOpen(" first second third forth"));
    }

    pub fn parse(str: []const u8) Rule {
        if (str.len < 3) return .empty;
        var s = str;
        const invert = str[0] == '-' or str[0] == '!';
        if (invert) s = s[1..];

        if (find(u8, s, ":")) |i| {
            if (i == 0) return .text(s, invert);
            const match = s[i + 1 ..];
            const pre: []const u8 = s[0..i];

            comptime {
                std.debug.assert(@typeInfo(Magic).@"enum".field_names.len == 7);
                // Don't forget to extend the if tree
            }

            if (eql(u8, pre, "is")) {
                return .is(match, invert);
            } else if (eql(u8, pre, "kind")) {
                return .kind(match, invert);
            } else if (eql(u8, pre, "rude")) {
                return .kind(match, !invert);
            } else if (eql(u8, pre, "only")) {
                return .only(match, invert);
            } else if (eql(u8, pre, "repo")) {
                return .repo(match, invert);
            } else if (eql(u8, pre, "owner")) {
                return .owner(match, invert);
            } else return .{
                .rule = .{ .target = .{ .tag = pre, .text = match } },
                .invert = invert,
            };
        } else return .{
            .rule = .{ .raw = s },
            .invert = invert,
        };
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

        const r11 = parse("kind:issues");
        try std.testing.expectEqualDeep(Rule{ .rule = .{ .kind = .issues } }, r11);
        const r12 = parse("kind:issue");
        try std.testing.expectEqualDeep(Rule{ .rule = .{ .kind = .issues } }, r12);

        const r13 = parse("rude:issues");
        try std.testing.expectEqualDeep(Rule{ .rule = .{ .kind = .issues }, .invert = true }, r13);
        const r14 = parse("!rude:issues");
        try std.testing.expectEqualDeep(Rule{ .rule = .{ .kind = .issues }, .invert = false }, r14);
    }

    pub fn format(r: Rule, w: *Writer) !void {
        if (r.invert) try w.writeByte('!');
        try w.print("{f}", .{r.rule});
    }
};

const Exclude = struct {
    list: ArrayList([]const u8),

    pub const empty: Exclude = .{
        .list = .empty,
    };

    fn checkSkip(e: *Exclude, path: []const u8) bool {
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
            if (self.evalRules(&current.result)) {
                return current;
            }
            return self.next(a, io);
        }

        fn evalRules(self: Self, target: *const Hit.Result) bool {
            log.debug("evalrules {} rules", .{self.rules.len});
            for (self.rules, 0..) |r, i| {
                const matches: bool = self.evalTarget(r.rule, target);
                log.debug(
                    "    rule {d: >3}[{f}] {c}{}",
                    .{ i, r.rule, if (r.invert) '!' else @as(u8, ' '), matches },
                );
                if (matches) {
                    if (r.invert) return false else continue;
                } else {
                    if (r.invert) continue else return false;
                }
            }
            log.debug("evalrules pass", .{});
            return true;
        }

        fn evalTarget(self: Self, rule: Rule.Query, hitr: *const Hit.Result) bool {
            switch (hitr.*) {
                .commit => return self.evalCommit(rule, &hitr.commit),
                .delta => return self.evalDelta(rule, &hitr.delta),
                .file => return self.evalFile(rule, &hitr.file),
                .repo => return self.evalRepo(rule, &hitr.repo),
            }
        }

        fn evalCommit(self: Self, rule: Rule.Query, commit: *const Hit.Result.Commit) bool {
            _ = self;
            _ = rule;
            _ = commit;
            return true;
        }

        fn evalDelta(self: Self, rule: Rule.Query, delta: *const Delta) bool {
            switch (rule) {
                .is => |is| switch (is) {
                    .open => return delta.state.isOpen(),
                    .closed => return delta.state.closed,
                },
                .kind, .only => |kind| switch (kind) {
                    .diffs => return delta.attach == .diff,
                    .issues => return (delta.attach == .issue or delta.attach == .remote),
                    .deltas => return true,
                    .commits => return false,
                    .repos => return false,
                    .files => return false,
                    .filenames => return false,
                },
                .owner => |owner| if (@hasField(Hit.Result, "owner")) {
                    log.debug("     rule owner '{s}' '{s}'", .{ owner, self.data.user });
                    if (eql(u8, owner, "me") and eql(u8, self.data.user, delta.owner))
                        return true
                    else
                        return eql(u8, self.data.user, delta.owner);
                } else {
                    log.debug("     " ++ @typeName(Hit.Result) ++ " has no owner [default true]", .{});
                    return true;
                },
                .raw => |raw| inline for (comptime std.meta.fieldNames(Delta)) |name| {
                    if (@TypeOf(@field(delta, name)) == []const u8) {
                        if (find(u8, @field(delta, name), raw)) |_| return true;
                    }
                } else return false,
                // null repos can't reach here anymore
                .repo => |repo| return eql(u8, delta.repo, repo),
                .target => |trgt| inline for (comptime std.meta.fieldNames(Delta)) |name| {
                    if (eql(u8, trgt.tag, name)) {
                        if (@TypeOf(@field(delta, name)) == []const u8) {
                            if (find(u8, @field(delta, name), trgt.text)) |_| {
                                return true;
                            }
                        }
                    }
                } else return false,
            }
        }

        fn evalFile(self: Self, rule: Rule.Query, commit: *const Hit.Result.File) bool {
            _ = self;
            _ = rule;
            _ = commit;
            return true;
        }

        fn evalRepo(self: Self, rule: Rule.Query, commit: *const Repo) bool {
            _ = self;
            _ = rule;
            _ = commit;
            return true;
        }

        pub fn raze(s: Self, io: Io) void {
            s.iterable.raze(io);
        }
    };
}

pub fn RepoTypeIterator(Type: type, Indexer: type, wrap: fn (Type) Hit.Result) type {
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

        pub fn raze(_: *const Self, _: Io) void {}

        pub fn next(self: *Self, a: Allocator, io: Io) ?Hit {
            while (self.index > 0) {
                defer self.index -|= 1;
                return .{ .result = wrap(Type.open(self.repo, self.index, a, io) catch continue) };
            }
            return null;
        }
    };
}

pub fn init(str: []const u8, d: Depth, a: Allocator) !Search {
    var rules: ArrayList(Rule) = .empty;
    var itr = splitScalar(u8, str, ' ');
    while (itr.next()) |r_line| {
        const line = trim(u8, r_line, " ");
        if (line.len == 0) continue;
        try rules.append(a, .parse(line));
    }

    var term_count: usize = 0;

    var only: ?Magic.Only = null;
    for (rules.items) |rule| switch (rule.rule) {
        .only => |o| if (only) |_| {
            return error.InvalidSearch;
        } else {
            only = o;
        },
        .raw, .target => term_count += 1,
        else => {},
    };

    return .{
        .alloc = a,
        .depth = d,
        .string = str,
        .rules = rules,
        .full_term_count = term_count,
        .repos = .empty,
        .hits = .empty,
        .only = only,
        .repo = null,
    };
}

pub fn raze(search: *Search, io: Io) void {
    for (search.repos.items) |*rep| rep.raze(search.alloc, io);
    search.repos.deinit(search.alloc);
    search.rules.deinit(search.alloc);
    search.hits.deinit(search.alloc);
}

pub fn searchAll(search: *Search, io: Io) !void {
    if (search.only) |only| {
        _ = only;
    }
    if (search.repos.items.len == 0) {
        try search.populateRepos(.public_only, io);
    }
    search.searchRepos(io) catch |err| {
        log.err("Search Delta error {} (continuing)", .{err});
    };
    search.searchDeltas(io) catch |err| {
        log.err("Search Delta error {} (continuing)", .{err});
    };
    if (search.full_term_count > 0) {
        search.searchCommits({}, io) catch |err| {
            log.err("Search Commit error {} (continuing)", .{err});
        };

        search.searchTrees(io) catch |err| {
            log.err("Search Commit error {} (continuing)", .{err});
        };
    }
}

pub fn populateRepos(search: *Search, vis: Repo.Visibility.Select, io: Io) !void {
    for (search.rules.items) |r| switch (r.rule) {
        .repo => |name| {
            if (r.invert) continue;
            var repo = (Repo.open(name, vis, io) catch continue) orelse continue;
            repo.name = search.alloc.dupe(u8, name) catch null;
            try search.repos.append(search.alloc, repo);
        },
        else => continue,
    };

    if (search.repos.items.len == 1) search.repo = &search.repos.items[0];
    if (search.repos.items.len > 0) return;
    var repo_iter = Repo.allRepoIterator(vis, io) catch return;

    while (repo_iter.next(io) catch return error.Unknown) |rep_| {
        var repo = rep_;
        if (!repo.pinned and search.depth == .quick) {
            repo.raze(search.alloc, io);
            continue;
        }
        repo.name = search.alloc.dupe(u8, repo_iter.current_name.?) catch null;
        try search.repos.append(search.alloc, repo);
    }

    if (search.repos.items.len == 1) search.repo = &search.repos.items[0];
}

pub fn searchRepos(search: *Search, io: Io) !void {
    const checked: usize = 0;
    defer search.meta.checked +|= checked;
    // TODO Search repo names
    // TODO Search Readmes
    _ = io;
}

pub fn searchCommits(search: *Search, age: void, io: Io) !void {
    var checked: usize = 0;
    defer search.meta.checked +|= checked;
    _ = age;
    for (search.repos.items) |*repo| {
        log.debug("search commits in {s}", .{repo.name.?});
        repo.git.loadData(search.alloc, io) catch |err| {
            log.err("Unable to load repo {s} [{}]", .{ repo.name.?, err });
        };
        const head = try repo.git.HEAD(search.alloc, io);
        var itr = head.iterate(&repo.git);
        var limit: u16 = if (search.only != null and search.only.? == .commits) 1000 else 200;
        while (itr.next(search.alloc, io) catch null) |cmt| {
            log.debug("commit {f}", .{cmt.sha.text()});
            if (limit == 0) break;
            limit -|= 1;
            var matching: bool = true;
            var owner: ?bool = null;
            for (search.rules.items) |r| {
                checked +|= 1;
                switch (r.rule) {
                    .raw => |raw| if (matching) {
                        if (find(u8, cmt.title, raw)) |_| {
                            matching = false;
                        }
                    },
                    .owner => |own| if (owner == null or !owner.?) {
                        if (find(u8, cmt.author.name, own)) |_| {
                            owner = true;
                        } else if (find(u8, cmt.committer.name, own)) |_| {
                            owner = true;
                        } else owner = false;
                    },
                    .target => {},
                    .is, .kind, .only, .repo => {},
                }
            }
            if (!matching and (owner == null or owner.?)) {
                try search.appendHit(
                    .{ .result = .{ .commit = .init(&cmt, repo.name.?) } },
                    .{ .repo = repo.name.? },
                );
            } else cmt.raze(search.alloc);
        }
    }
}

pub fn searchDeltas(search: *Search, io: Io) !void {
    var checked: usize = 0;
    defer search.meta.checked +|= checked;
    for (search.repos.items) |*repo| {
        log.debug("search delta in {s}", .{repo.name.?});
        var itr = Delta.searchRepo(repo.name.?, search.rules.items, io);
        defer itr.raze(io);
        while (itr.nextDelta(search.alloc, io)) |delta| {
            checked +|= 1;
            log.debug("delta {}", .{delta.index});
            if (delta.state.embargoed) continue;
            try search.appendHit(
                .{ .result = .{ .delta = delta } },
                .{ .repo = repo.name.? },
            );
        }
    }
}

pub fn reposFor(rules: *const Search) ![]S.SearchHtml.SearchResults {
    _ = rules;
    return &.{};
}

pub fn searchTrees(search: *Search, io: Io) !void {
    var limit: u32 = if (search.only != null and search.only.? == .commits) 2000 else 500;

    for (search.repos.items) |*repo| {
        log.debug("search tree in {s}", .{repo.name.?});
        repo.git.loadData(search.alloc, io) catch |err| {
            log.err("Unable to load repo {s} [{}]", .{ repo.name.?, err });
        };

        const head = try repo.git.HEAD(search.alloc, io);
        const tree = try head.loadTree(&repo.git, search.alloc, io);
        try search.searchTree(&tree, repo, &.{}, &limit, io);
    }
}

fn searchTree(
    search: *Search,
    tree: *const git.Tree,
    repo: *Repo,
    root_path: []const u8,
    limit: *u32,
    io: Io,
) !void {
    var checked: usize = 0;
    defer search.meta.checked +|= checked;
    var itr = tree.iterate();
    while (itr.next()) |obj| {
        if (limit.* == 0) break;
        std.debug.assert(root_path.len == 0 or root_path[root_path.len - 1] == '/');
        const path = try search.alloc.print("{s}{s}/", .{ root_path, obj.name });
        log.debug("tree search {s} -> {s}", .{ repo.name.?, path });
        if (search.excluded.checkSkip(path)) {
            // TODO optimize this alloc
            search.alloc.free(path);
            continue;
        }
        limit.* -|= 1;
        var object = repo.git.objects.load(obj.sha, search.alloc, io) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ShaNotFound,
            error.ObjectMissing,
            error.ObjectCorrupt,
            error.ObjectInvalid,
            error.FileNotFound,
            error.NameTooLong,
            error.BadPathName,
            => return error.CorruptRepo,
            error.StreamTooLong => continue,
            error.Canceled => return,
            error.SystemResources,
            error.AccessDenied,
            error.PermissionDenied,
            error.NoDevice,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.NetworkNotFound,
            error.SymLinkLoop,
            error.OtherFileSys,
            => return error.Io,
            error.Ambiguous => unreachable, // corrupted repo?
            error.NotDir => unreachable,
            error.Unexpected => unreachable,
        };
        switch (object) {
            .tree => |*t| for (search.rules.items) |r| {
                checked +|= 1;
                switch (r.rule) {
                    .owner => {}, // TODO check repo owners file
                    .only => |only| if (only != .filenames) return,
                    .raw => |raw| if (find(u8, path, raw)) |_| {
                        try search.appendHit(.{ .result = .{
                            .file = .{
                                .repo_name = repo.name.?,
                                .path = path,
                                .sha = t.sha.text(),
                                .hit_idx = 0,
                                .line = 0,
                                .line_count = 0,
                                .code = &.{},
                            },
                        } }, .{ .filename = .{ .repo = repo.name.?, .path = path } });
                    },
                    .is, .kind, .repo, .target => {},
                }
            } else search.searchTree(t, repo, path, limit, io) catch |err| {
                log.err("search error {}", .{err});
                continue;
            },
            .blob => |*b| for (search.rules.items) |r| {
                switch (r.rule) {
                    .owner => {}, // TODO check repo owners file
                    .only => |only| if (only == .filenames) continue,
                    .raw => |raw| if (find(u8, path, raw)) |_| {
                        try search.appendHit(.{ .result = .{
                            .file = .{
                                .repo_name = repo.name.?,
                                .path = path[0 .. path.len - 1],
                                .sha = b.sha.text(),
                                .hit_idx = 0,
                                .line = 0,
                                .line_count = 0,
                                .code = &.{},
                            },
                        } }, .{ .filename = .{ .repo = repo.name.?, .path = path[0 .. path.len - 1] } });
                    },
                    .is, .kind, .repo, .target => {},
                }
            } else try search.searchInBlob(repo, path[0 .. path.len - 1], b),

            .commit, .tag => return error.CorruptedRepo,
        }
    }
}

fn searchInBlob(search: *Search, repo: *Repo, path: []const u8, b: *git.Blob) !void {
    if (find(u8, b.data.blob, "anstehusnaotehn")) |idx| {
        const found_line = countScalar(u8, b.data.blob[0..idx], '\n');
        const line_count = countScalar(u8, b.data.blob[idx..], '\n');
        try search.appendHit(.{ .result = .{
            .file = .{
                .repo_name = repo.name.?,
                .path = path,
                .sha = b.sha.text(),
                .hit_idx = idx,
                .line = @truncate(found_line),
                .line_count = @truncate(found_line + line_count),
                .code = b.data.blob,
            },
        } }, .{ .filename = .{ .repo = repo.name.?, .path = path } });
    }
}

const From = union(enum) {
    repo: []const u8,
    filename: struct {
        path: []const u8,
        repo: []const u8,
    },
};

fn appendHit(search: *Search, hit: Hit, from: From) !void {
    try search.hits.append(search.alloc, hit);
    switch (from) {
        .repo => |name| {
            const ptr = try search.meta.repos.getOrPut(search.alloc, name);
            if (!ptr.found_existing) {
                ptr.key_ptr.* = name;
                ptr.value_ptr.* = 0;
            }
            ptr.value_ptr.* +|= 1;
        },
        .filename => |fnm| {
            const rptr = try search.meta.repos.getOrPut(search.alloc, fnm.repo);
            if (!rptr.found_existing) {
                rptr.key_ptr.* = fnm.repo;
                rptr.value_ptr.* = 0;
            }
            rptr.value_ptr.* +|= 1;

            const fptr = try search.meta.files.getOrPut(search.alloc, fnm.path);
            if (!fptr.found_existing) {
                fptr.key_ptr.* = fnm.path;
                fptr.value_ptr.* = 0;
            }
            fptr.value_ptr.* +|= 1;
        },
    }

    switch (hit.result) {
        .repo => {},
        .commit => {},
        .file => {},
        .delta => |d| switch (d.attach) {
            inline else => |tag| {
                const name = @tagName(tag);
                const ptr = try search.meta.deltas.getOrPut(search.alloc, name);
                if (!ptr.found_existing) {
                    ptr.key_ptr.* = name;
                    ptr.value_ptr.* = 0;
                }
                ptr.value_ptr.* +|= 1;
            },
        },
    }
}

const extra_lines: usize = 6;

pub fn searchFiles(
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
    var excludes: Exclude = .empty;
    try excludes.fromRepo(&repo.git, &tree, search.alloc, io);
    try excludes.fromSearch(search.string, search.alloc);
    defer excludes.list.deinit(search.alloc);
    for (excludes.list.items) |ex| log.info("tree exclude {s}", .{ex});
    // TODO real tokenization
    try search.searchTree(&tree, repo, &.{}, &limit, io);

    var hits: ArrayList(S.SearchFlavor.File) = try .initCapacity(search.alloc, file_list.items.len);
    for (file_list.items) |hit| {
        var start: usize = hit.hit_idx;
        var before: usize = extra_lines;
        while (start > 0 and before > 0) : (start -|= 1) {
            if (hit.code[start] == '\n') before -|= 1;
        }
        var end: usize = hit.hit_idx;
        var after: usize = extra_lines;
        while (end < hit.code.len and after > 0) : (end += 1) {
            if (hit.code[end] == '\n') after -|= 1;
        }
        if (start > 0) start += 2;
        const code = hit.code[start .. end - 1];
        const start_number = countScalar(u8, code[0 .. hit.hit_idx - start], '\n');
        const file_lines = countScalar(u8, code[hit.hit_idx - start ..], '\n');
        var line_number = hit.line + 1 - start_number;
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
            .code = .{
                .lines = .safe(writer.written()),
                .line_count = file_lines + start_number,
                .language = .safe((syntax.Language.guessFromName(hit.path) orelse syntax.Language.txt).toString()),
            },
        });
    }

    return try hits.toOwnedSlice(search.alloc);
}

test Search {
    _ = &std.testing.refAllDecls(Search);

    var search: Search = try .init("repo:srctree owner:grayhatter verse", .deep, std.testing.allocator);
    defer search.raze(std.testing.io);

    try std.testing.expectEqualDeep(Search{
        .alloc = std.testing.allocator,
        .depth = .deep,
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
        .full_term_count = 1,
        .repos = .empty,
        .hits = .empty,
        .only = null,
        .repo = null,
    }, search);

    search.raze(std.testing.io);
    search = try .init("srctree", .quick, std.testing.allocator);
    try std.testing.expectEqualDeep(Search{
        .alloc = std.testing.allocator,
        .depth = .quick,
        .string = "srctree",
        .rules = .{
            .items = @constCast(&[_]Rule{
                .{ .rule = .{ .raw = "srctree" } },
            }),
            .capacity = 3,
            .pointer_stability = .{},
        },
        .full_term_count = 1,
        .repos = .empty,
        .hits = .empty,
        .only = null,
        .repo = null,
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
const syntax = @import("syntax.zig");

const findPos = std.mem.findPos;
const findScalarPos = std.mem.findScalarPos;
const countScalar = std.mem.countScalar;

const verse = @import("verse");
const T = verse.template;
const S = T.Structs;
const abx = verse.Antibiotic;
