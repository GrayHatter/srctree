pub const verse_name = .diffs;

pub const verse_aliases = .{
    .diff,
};

pub const verse_router: Route.RouteFn = router;

pub const routes = [_]Route.Match{
    ROUTE("", list),
    ROUTE("new", new),
    POST("create", createDiff),
    POST("add-comment", newComment),
};

pub const index = list;

fn isHex(input: []const u8) ?usize {
    for (input) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return std.fmt.parseInt(usize, input, 16) catch null;
}

pub fn router(ctx: *Frame) Route.RoutingError!Route.BuildFn {
    const current = ctx.uri.next() orelse return error.Unrouteable;
    if (!eql(u8, "diffs", current) and !eql(u8, "diff", current)) return error.Unrouteable;

    const verb = ctx.uri.peek() orelse return Route.defaultRouter(ctx, &routes);

    if (isHex(verb)) |_| {
        var uri_d = ctx.uri;
        _ = uri_d.next();
        if (uri_d.peek()) |action| {
            if (eql(u8, action, "direct_reply")) return directReply;
        }

        if (ctx.request.method == .POST)
            return updatePatch
        else
            return view;
    }

    return Route.defaultRouter(ctx, &routes);
}

const DiffNewHtml = Template.PageData("diff-new.html");

const DiffCreateReq = struct {
    from_network: ?bool = null,
    from_uri: ?bool = null,
    from_paste: ?bool = null,
    from_curl: ?bool = null,

    title: []const u8,
    desc: []const u8,

    patch_uri: ?[]const u8 = null,
    patch: ?[]const u8 = null,
    network: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    via_curl: ?[]const u8 = null,
};

fn new(f: *Frame) Error!void {
    return switch (f.request.method) {
        .GET => pendingNew(f),
        .POST => newPOST(f),
        .PUT => newPUT(f),
        else => pendingNew(f),
    };
}

fn newPUT(f: *Frame) Error!void {
    std.debug.print("new put {any}\n", .{f.request.data});
    return pendingNew(f);
}

fn newPOST(f: *Frame) Error!void {
    // TODO implementent
    return pendingNew(f);
}

fn pendingNew(f: *Frame) Error!void {
    var patch_network: ?S.DiffNewHtml.PatchNetwork = null;
    var patch_uri: ?S.DiffNewHtml.PatchUri = null;
    var patch_paste: ?S.DiffNewHtml.PatchPaste = null;
    var patch_curl: ?S.DiffNewHtml.PatchCurl = null;
    var title: ?[]const u8 = null;
    var desc: ?[]const u8 = null;

    const routing_data = RouteData.init(f.uri) orelse return error.Unrouteable;
    var repo = (repos.open(routing_data.name, .public, f.io) catch return error.DataInvalid) orelse return error.DataInvalid;
    repo.loadData(f.alloc, f.io) catch return error.ServerFault;
    defer repo.raze(f.alloc, f.io);

    if (f.request.data.post) |post| {
        const udata = post.validate(DiffCreateReq) catch return error.DataInvalid;
        title = udata.title;
        desc = udata.desc;

        if (udata.from_paste) |_| {
            patch_paste = .{};
        } else if (udata.from_network) |_| {
            const remotes = repo.remotes orelse unreachable;
            const network_remotes = try f.alloc.alloc(S.DiffNewHtml.PatchNetwork.Remotes, remotes.len);
            for (remotes, network_remotes) |src, *dst| {
                dst.* = .{
                    .value = src.name,
                    .name = try allocPrint(f.alloc, "{f}", .{std.fmt.alt(src, .formatDiff)}),
                };
            }

            patch_network = .{
                .remotes = network_remotes,
                .branches = &.{
                    .{ .value = "main", .name = "main" },
                    .{ .value = "develop", .name = "develop" },
                    .{ .value = "master", .name = "master" },
                },
            };
        } else if (udata.patch_uri) |_| {
            patch_uri = .{};
        } else {
            patch_curl = .{};
        }
    } else {
        patch_curl = .{};
    }

    var body_header: S.BodyHeaderHtml = .{ .nav = .{ .nav_buttons = &try RepoEndpoint.navButtons(f) } };
    if (f.user) |usr| {
        body_header.nav.nav_auth = usr.username.?;
    }
    var page = DiffNewHtml.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = body_header,
        .err = null,
        .title = title,
        .desc = desc,
        .patch_network = patch_network,
        .patch_uri = patch_uri,
        .patch_paste = patch_paste,
        .patch_curl = patch_curl,
    });

    try f.sendPage(&page);
}

fn inNetwork(str: []const u8) bool {
    //if (!std.mem.startsWith(u8, str, "https://srctree.gr.ht")) return false;
    //for (str) |c| if (c == '@') return false;
    _ = str;
    return true;
}

const DiffUpdateReq = struct {
    author: ?[]const u8 = null,
    patch: []const u8,
};

fn updatePatch(f: *Frame) Error!void {
    std.debug.print("update\n", .{});
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;

    const delta_id = f.uri.next().?;
    const idx = isHex(delta_id) orelse return error.InvalidURI;

    const post = f.request.data.post orelse return error.DataMissing;
    std.debug.print("post {any}\n", .{post});
    for (post.items) |itm| {
        std.debug.print("post itm {any}\n", .{itm});
    }
    const udata = post.validate(DiffUpdateReq) catch return error.DataInvalid; // TODO return custom text for curl

    var delta = Delta.open(rd.name, idx, f.alloc, f.io) catch return error.Unknown;

    const author: []const u8 = &.{};
    var diff: Diff = Diff.new(&delta, author, udata.patch, f.alloc, f.io) catch |err| {
        std.debug.print("unable to create new diff {}\n", .{err});
        unreachable;
    };
    diff.state = .curl;
    diff.commit(f.io) catch unreachable;
}

fn createDiffCore(rd: RouteData, req: DiffCreateReq, user: []const u8, a: Allocator, io: Io) !usize {
    if (req.title.len == 0) return error.DataInvalid;

    if (req.patch_uri) |uri| {
        if (inNetwork(uri)) {
            const data = try Patch.fromRemote(uri, a, io);

            std.debug.print(
                "src {s}\ntitle {s}\ndesc {s}\naction {s}\n",
                .{ uri, req.title, req.desc, "unimplemented" },
            );
            var delta = Delta.new(rd.name, req.title, req.desc, user, io) catch return error.ServerError;
            delta.commit(io) catch unreachable;

            const diff: Diff = Diff.new(&delta, user, data.blob, a, io) catch |err| {
                std.debug.print("unable to create new diff {}\n", .{err});
                unreachable;
            };
            _ = diff;
            return delta.index;
        }
    } else if (req.via_curl) |_| {
        std.debug.print(
            "title {s}\ndesc {s}\naction {s}\n",
            .{ req.title, req.desc, "unimplemented" },
        );
        var delta = Delta.new(rd.name, req.title, req.desc, user, io) catch return error.ServerError;
        try delta.commit(io);
        var diff: Diff = Diff.new(&delta, user, "", a, io) catch |err| {
            std.debug.print("unable to create new diff {}\n", .{err});
            unreachable;
        };
        diff.state = .pending_curl;
        try diff.commit(io);
        try delta.commit(io);
        return delta.index;
    }
    return error.Unknown;
}

fn createDiff(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    if (f.request.data.post) |post| {
        const udata = post.validate(DiffCreateReq) catch return error.DataInvalid;
        const username = if (f.user) |usr|
            usr.username.?
        else
            try allocPrint(f.alloc, "REMOTE_ADDR {s}", .{f.request.remote_addr});

        const idx = createDiffCore(rd, udata, username, f.alloc, f.io) catch {
            return createError(f, udata, .{ .remote_error = "connection failed" });
        };

        var buf: [2048]u8 = undefined;
        const loc = try bufPrint(&buf, "/repo/{s}/diff/{x}", .{ rd.name, idx });
        return f.redirect(loc, .see_other) catch unreachable;
    }

    return try new(f);
}

const ErrStrs = union(enum) {
    remote_error: []const u8,
    unknown,
};

fn createError(ctx: *Frame, udata: DiffCreateReq, comptime err: ErrStrs) Error!void {
    var page = DiffNewHtml.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .nav = .{ .nav_buttons = &try RepoEndpoint.navButtons(ctx) } },
        .err = switch (err) {
            .remote_error => |str| .{ .error_string = "Unable to fetch patch from remote (" ++ str ++ ")" },
            else => .{ .error_string = "error" },
        },
        .title = try std.fmt.allocPrint(ctx.alloc, "{f}", .{abx.Html{ .text = udata.title }}),
        .desc = try std.fmt.allocPrint(ctx.alloc, "{f}", .{abx.Html{ .text = udata.desc }}),
        .patch_network = if (udata.network) |_| null else null, // TODO fixme
        .patch_uri = if (udata.patch_uri) |uri| .{ .uri = try std.fmt.allocPrint(ctx.alloc, "{f}", .{abx.Html{ .text = uri }}) } else null,
        .patch_paste = if (udata.patch) |pst| .{ .patch_blob = try std.fmt.allocPrint(ctx.alloc, "{f}", .{abx.Html{ .text = pst }}) } else null,
        .patch_curl = if (udata.via_curl) |_| .{} else null,
    });

    try ctx.sendPage(&page);
}

const NewCmtReq = struct {
    did: []const u8,
    diff_id: []const u8,
    comment: []const u8,
};

fn newComment(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    var buf: [2048]u8 = undefined;
    if (f.request.data.post) |post| {
        var valid = post.validate(NewCmtReq) catch return error.DataInvalid;
        const delta_index = isHex(valid.did) orelse return error.Unrouteable;
        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/diff/{x}", .{ rd.name, delta_index });

        if (valid.comment.len < 2) return f.redirect(loc, .see_other) catch unreachable;

        var delta = Delta.open(rd.name, delta_index, f.alloc, f.io) catch return error.Unknown;
        const username = if (f.user) |usr| usr.username.? else "public";
        var msg = delta.addComment(.{ .author = username, .message = valid.comment }, f.alloc, f.io) catch return error.Unknown;
        msg.extra0 = std.fmt.parseInt(usize, valid.diff_id, 10) catch return error.DataInvalid;
        msg.commit(f.io) catch return error.ServerFault;
        // TODO record current revision at comment time
        return f.redirect(loc, .see_other) catch unreachable;
    }
    return error.Unknown;
}

pub fn directReply(ctx: *Frame) Error!void {
    _ = ctx.uri.next().?;
    _ = ctx.uri.next().?;
    std.debug.print("{s}\n", .{ctx.uri.next().?});
    return error.Unknown;
}

pub fn patchStruct(a: Allocator, patch: *Patch, view_mode: PatchViewMode) !S.PatchHtml {
    patch.parse(a) catch |err| {
        if (std.mem.indexOf(u8, patch.blob, "\nMerge: ") == null) {
            std.debug.print("err: {any}\n", .{err});
            //std.debug.print("'''\n{s}\n'''\n", .{patch.blob});
            return err;
        } else {
            std.debug.print("Unable to parse diff {} (merge commit)\n", .{err});
            return error.UnableToGeneratePatch;
        }
    };

    const diffs = patch.diffs orelse unreachable;
    const files = try a.alloc(S.PatchHtml.Files, diffs.len);
    errdefer a.free(files);
    for (diffs, files) |diff, *file| {
        const body = diff.changes orelse continue;

        const dstat = patch.patchStat();
        const stat = try allocPrint(
            a,
            "added: {}, removed: {}, total {}",
            .{ dstat.additions, dstat.deletions, dstat.total },
        );
        //<div class="<DClass />"><ln num="<Num type="usize" />" id="LL<Num type="usize" />" href="#LL<Num type="usize" />"><Line /></ln></div>
        const name = if (diff.filename) |name| try allocPrint(a, "{s}", .{name}) else switch (diff.header.change) {
            .deletion => "File Was Deleted",
            else => "File Was Added",
        };
        file.* = .{
            .diff_stat = stat,
            .filename = name,
            .patch_inline = null,
            .patch_split = null,
        };
        const patch_lines = try Patch.diffLineHtmlUnified(a, body);
        if (view_mode == .split) {
            const split: Patch.Split = try .fromParsed(patch_lines, a);
            var lines_left: ArrayList([]u8) = .{};
            var lines_right: ArrayList([]u8) = .{};
            for (split.left) |left| try lines_left.append(a, switch (left) {
                .hdr => |hdr| try allocPrint(a, "<div class=\"block\">{s}</div>", .{hdr.text}),
                .add => unreachable,
                .del => |del| try allocPrint(
                    a,
                    "<div class=\"del\"><ln num=\"{0d}\" id=\"LL{0d}\" href=\"#LL{0d}\">{1s}</ln></div>",
                    .{ del.number, del.text },
                ),
                .ctx => |ctx| try allocPrint(
                    a,
                    "<div><ln num=\"{0d}\" id=\"LL{0d}\" href=\"#LL{0d}\">{1s}</ln></div>",
                    .{ ctx.number, ctx.text },
                ),
                .nul => try allocPrint(a, "<div class=\"nul\"></div>", .{}),
            });
            for (split.right) |right| try lines_right.append(a, switch (right) {
                .hdr => |hdr| try allocPrint(a, "<div class=\"block\">{s}</div>", .{hdr.text}),
                .add => |add| try allocPrint(
                    a,
                    "<div class=\"add\"><ln num=\"{0d}\" id=\"RL{0d}\" href=\"#RL{0d}\">{1s}</ln></div>",
                    .{ add.number, add.text },
                ),
                .del => unreachable,
                .ctx => |ctx| try allocPrint(
                    a,
                    "<div><ln num=\"{0d}\" id=\"RL{0d}\" href=\"#RL{0d}\">{1s}</ln></div>",
                    .{ ctx.number_right, ctx.text },
                ),
                .nul => try allocPrint(a, "<div class=\"nul\"></div>", .{}),
            });
            file.*.patch_split = .{
                .diff_lines_left = try lines_left.toOwnedSlice(a),
                .diff_lines_right = try lines_right.toOwnedSlice(a),
            };
        } else {
            var lines: ArrayList([]u8) = .{};
            for (patch_lines) |line| {
                try lines.append(a, switch (line) {
                    .hdr => |hdr| try allocPrint(a, "<div class=\"block\">{s}</div>", .{hdr.text}),
                    .ctx => |ctx| try allocPrint(
                        a,
                        "<div><ln num=\"{0d}\" href=\"#L{1d}\"></ln><ln num=\"{1d}\" id=\"L{1d}\" href=\"#L{1d}\">{2s}</ln></div>",
                        .{ ctx.number, ctx.number_right, ctx.text },
                    ),
                    .del => |del| try allocPrint(
                        a,
                        "<div class=\"del\"><ln num=\"{0d}\" href=\"#LL{0d}\"></ln><ln id=\"LL{0d}\" href=\"#LL{0d}\">{1s}</ln></div>",
                        .{ del.number, del.text },
                    ),
                    .add => |add| try allocPrint(
                        a,
                        "<div class=\"add\"><ln href=\"#RL{0d}\"></ln><ln num=\"{0d}\" id=\"RL{0d}\" href=\"#RL{0d}\">{1s}</ln></div>",
                        .{ add.number_right, add.text },
                    ),
                    .nul => unreachable,
                });
            }
            file.patch_inline = .{
                .diff_lines = try lines.toOwnedSlice(a),
            };
        }
    }
    return .{
        .files = files,
    };
}

const ParsedHeader = struct {
    pub const Numbers = struct {
        start: u32,
        change: u32,
    };
    left: Numbers,
    right: Numbers,
};

fn getLineFrom(data: []const u8, target: u32, length: u32) !?[]const u8 {
    _ = data;
    _ = target;
    _ = length;
    return null;
}

fn getCodeAt(data: []const u8, target: u32, length: u32, right_only: bool) !?[]const u8 {
    var start: usize = findScalarPos(u8, data, 0, '\n') orelse return error.BadDiff;
    var len = length;
    const header = try parseBlockHeader(data[0..start]);
    var current_line: usize = header.right.start;
    var block: []const u8 = &.{};
    start += 1;
    while (findScalarPos(u8, data, start, '\n')) |nl| {
        if (len == 0) break;
        defer start = nl + 1;
        const line = data[start..nl];
        switch (line[0]) {
            '-' => {
                if (!right_only) {
                    if (current_line >= target) {
                        if (current_line == target) block = line else block.len += 1 + nl - start;
                        len -|= 1;
                    }
                    current_line += 1;
                }
            },
            '+' => {
                if (right_only) {
                    if (current_line >= target) {
                        if (current_line == target) block = line else block.len += 1 + nl - start;
                        len -|= 1;
                    }
                    current_line += 1;
                }
            },
            ' ' => {
                if (current_line >= target) {
                    if (current_line == target) block = line else block.len += 1 + nl - start;
                    len -|= 1;
                }
                current_line += 1;
            },
            else => {},
        }
    }
    return if (block.len == 0) null else block;
}

/// TODO move to patch.zig
fn parseBlockHeader(string: []const u8) !ParsedHeader {
    const end = find(u8, string[3..], " @@") orelse return error.InvalidBlockHeader;
    const offsets = string[3 .. end + 3];
    const mid = find(u8, offsets, " ") orelse unreachable;
    const left = offsets[1..mid];
    const right = offsets[mid + 2 ..];
    const left_mid = find(u8, left, ",") orelse unreachable;
    const l_low = try parseInt(u32, left[0..left_mid], 10);
    const l_high = try parseInt(u32, left[left_mid + 1 ..], 10);
    const right_mid = find(u8, right, ",") orelse unreachable;
    const r_low = try parseInt(u32, right[0..right_mid], 10);
    const r_high = try parseInt(u32, right[right_mid + 1 ..], 10);
    return .{
        .left = .{ .start = l_low, .change = l_high },

        .right = .{ .start = r_low, .change = r_high },
    };
}

fn highlightLineRef(
    text: []const u8,
    code: []const u8,
    filename: []const u8,
    color: []const u8,
    a: Allocator,
    io: Io,
) ![]u8 {
    const formatted = if (code.len == 0)
        "&nbsp;"
    else if (Highlighting.Language.guessFromFilename(filename)) |lang|
        try Highlighting.highlight(lang, code, a, io)
    else
        try allocPrint(a, "{f}", .{abx.Html{ .text = code }});

    return try allocPrint(a, "<div title=\"{s}\" class=\"coderef{s}\">{s}</div>", .{
        try allocPrint(a, "{f}", .{abx.Html{ .text = text }}), color, formatted,
    });
}

fn resolveLineRefRepo(
    line: []const u8,
    filename: []const u8,
    repo: *const Git.Repo,
    line_ref: LineRef,
    a: Allocator,
    io: Io,
) !?[][]const u8 {
    var found_lines: ArrayList([]const u8) = .{};

    const cmt = try repo.headCommit(a, io);
    var files: Git.Tree = try cmt.loadTree(repo, a, io);
    var itr = splitScalar(u8, filename, '/');
    const blob_sha: Git.Sha = root: while (itr.next()) |dirname| {
        for (files.blobs) |obj| {
            if (eql(u8, obj.name, dirname)) {
                if (obj.isFile()) {
                    if (itr.peek() != null) return null;
                    break :root obj.sha;
                }
                files = try obj.toTree(repo, a, io);
                continue :root;
            }
        } else {
            std.debug.print("unable to resolve file {s} at {s}\n", .{ filename, dirname });
            return null;
        }
    } else return null;

    var file = try repo.loadBlob(blob_sha, a, io);
    var start: usize = 0;
    var end: usize = 0;
    var count: usize, var stride: usize = switch (line_ref) {
        .number => |n| .{ n, 0 },
        .stride => |s| .{ s.number, s.stride - s.number },
        .tag => return null,
    };
    while (findScalarPos(u8, file.data.?, @max(end, start) + 1, '\n')) |next| {
        if (count > 1) {
            start = next;
        } else if (count == 1) {
            end = next;
            if (stride > 0) {
                stride -= 1;
                continue;
            }
            break;
        }
        count -|= 1;
    }
    if (count > 1) return error.LineNotFound;
    const found_line = file.data.?[start..end];

    try found_lines.append(a, try highlightLineRef(line, found_line[1..], filename, "", a, io));
    return try found_lines.toOwnedSlice(a);
}

fn resolveLineRefDiff(
    line: []const u8,
    filename: []const u8,
    diff: *Patch.Diff,
    line_ref: LineRef,
    fpos: usize,
    a: Allocator,
    io: Io,
) !?[][]const u8 {
    const number, const ncount = switch (line_ref) {
        .number => |n| .{ n, 1 },
        .stride => |s| .{ s.number, 1 + s.stride - s.number },
        .tag => unreachable,
    };
    const add_side: ?bool = switch (if (fpos > 0) line[fpos - 1] else ' ') {
        '+' => true,
        '-' => false,
        else => null,
    };
    var found_lines: ArrayList([]const u8) = .{};
    const blocks = try diff.blocksAlloc(a);
    for (blocks) |block| {
        const change = try parseBlockHeader(block);
        const in_left = number >= change.left.start and number <= change.left.start + change.left.change;
        const in_right = number >= change.right.start and number <= change.right.start + change.right.change;
        if (in_left or in_right) {
            if (try getCodeAt(block, number, ncount, add_side orelse true)) |code| {
                const color = switch (code[0]) {
                    '+' => " green",
                    '-' => " red",
                    ' ' => " yellow",
                    else => " error",
                };
                var fixed_code = code[1..];
                if (std.mem.count(u8, code[1 .. code.len - 1], "\n") > 0) {
                    var fixed = try a.alloc(u8, code.len);
                    var i: usize = 0;
                    var slide: usize = 1;
                    while (slide < code.len) {
                        fixed[i] = code[slide];
                        i += 1;
                        if (code[slide] == '\n') {
                            slide += 2;
                        } else {
                            slide += 1;
                        }
                    }
                    fixed_code = fixed[0..i];
                }

                try found_lines.append(a, try highlightLineRef(line, fixed_code, filename, color, a, io));
            }
            break;
        }
    } else return null;
    return try found_lines.toOwnedSlice(a);
}

const LineRef = union(enum) {
    number: u32,
    stride: Stride,
    tag: Tag,

    pub const Stride = struct {
        number: u32,
        stride: u32,
    };
    pub const Tag = []const u8;
};

const FileLineRef = struct {
    file: []const u8,
    line: LineRef,
};

fn lineRef(target: []const u8) !LineRef {
    std.debug.assert(target.len > 1);
    switch (target[0]) {
        '@' => {
            return .{ .tag = target[1..] };
        },
        '#', ':' => {
            var search_end: usize = 1;
            while (search_end < target.len and isDigit(target[search_end])) search_end += 1;
            const number = try parseInt(u32, target[1..search_end], 10);

            if (target.len > search_end) strd: {
                switch (target[search_end]) {
                    '-', '+' => |op| {
                        const stride_start = search_end + 1;
                        var stride_end = stride_start;
                        while (stride_end < target.len and isDigit(target[stride_end])) stride_end += 1;
                        const stride = parseInt(u32, target[stride_start..stride_end], 10) catch break :strd;
                        return .{ .stride = .{
                            .number = number,
                            .stride = if (op == '+') stride + number else stride,
                        } };
                    },
                    else => {},
                }
            }

            return .{ .number = number };
        },
        else => return error.InvalidSpecifier,
    }
    return error.InvalidLineTarget;
}

test lineRef {
    const left = (try lineRef("#10")).number;
    try std.testing.expectEqual(10, left);

    const stride = (try lineRef("#10-20")).stride;
    try std.testing.expectEqual(10, stride.number);
    try std.testing.expectEqual(20, stride.stride);
}

fn fileLineRef(str: []const u8) ?FileLineRef {
    var w_start: usize = 0;

    while (w_start + 3 < str.len) {
        w_start = findAnyPos(u8, str, w_start, "/.") orelse return null;
        var file_start = w_start;
        while (file_start > 0 and str[file_start] != ' ') file_start -= 1;
        if (str[file_start] == ' ') file_start += 1;

        if (findAnyPos(u8, str, w_start, " #:@")) |loc| {
            w_start = loc;
            if (str[loc] == ' ') continue;
            const line_ref = lineRef(str[loc..]) catch return null;
            return .{
                .file = str[file_start..loc],
                .line = line_ref,
            };
        } else w_start += 1;
    }
    return null;
}

test fileLineRef {
    try std.testing.expect(fileLineRef("") == null);
    try std.testing.expect(fileLineRef("src/main.zig") == null);
    try std.testing.expect(fileLineRef("srcmainzig#11") == null);

    try std.testing.expectEqualDeep(
        FileLineRef{ .file = "src/main.zig", .line = .{ .number = 12 } },
        fileLineRef("src/main.zig#12").?,
    );
    try std.testing.expectEqualDeep(
        FileLineRef{ .file = "src/main.zig", .line = .{ .number = 12 } },
        fileLineRef("src/main.zig:12").?,
    );
    // Wrong, but currently unimplemented
    try std.testing.expectEqualDeep(
        FileLineRef{ .file = "src/main.zig", .line = .{ .tag = "12" } },
        fileLineRef("src/main.zig@12").?,
    );

    try std.testing.expectEqualDeep(
        FileLineRef{ .file = "src/srctree.zig", .line = .{ .number = 13 } },
        fileLineRef("some before text src/srctree.zig#13 and some after text").?,
    );

    try std.testing.expectEqualDeep(
        FileLineRef{ .file = "main.zig", .line = .{ .number = 14 } },
        fileLineRef("main.zig#14").?,
    );
    try std.testing.expectEqualDeep(
        FileLineRef{ .file = "src/main", .line = .{ .number = 15 } },
        fileLineRef("src/main#15").?,
    );
}

const TrnsCmt = struct { bool, []u8 };
pub fn translateComment(comment: []const u8, patch: Patch, repo: *const Git.Repo, a: Allocator, io: Io) !TrnsCmt {
    var message_lines: ArrayList([]const u8) = .{};
    defer message_lines.clearAndFree(a);
    var found_ref = false;
    var itr = splitScalar(u8, comment, '\n');
    const diffs: []Patch.Diff = patch.diffs orelse &.{};
    while (itr.next()) |line_| {
        const line = std.mem.trim(u8, line_, "\r ");
        for (diffs) |*diff| {
            const filename = diff.filename orelse continue;
            // Files changed in the diff can be bare referenced without a prefix.
            if (find(u8, line, filename)) |filepos| {
                if (findAnyPos(u8, line, filepos, "#:@")) |h| {
                    const line_ref = try lineRef(line[h..]);

                    // default to
                    if (try resolveLineRefDiff(line, filename, diff, line_ref, filepos, a, io)) |code| {
                        found_ref = true;
                        try message_lines.appendSlice(a, code);
                        var end: usize = h;
                        while (end < line.len and !isWhitespace(line[end])) {
                            end += 1;
                        }
                        if (end < line.len)
                            try message_lines.append(a, try allocPrint(a, "{f}", .{
                                abx.Html{ .text = line[end..] },
                            }));
                    } else if (resolveLineRefRepo(line, filename, repo, line_ref, a, io) catch |err| switch (err) {
                        error.LineNotFound => null,
                        else => return err,
                    }) |code| {
                        found_ref = true;
                        try message_lines.appendSlice(a, code);
                    } else {
                        try message_lines.append(a, try allocPrint(
                            a,
                            "<span title=\"line not found in this diff\">{f}</span>",
                            .{abx.Html{ .text = line }},
                        ));
                    }
                }
                break;
            }
        } else {
            try message_lines.append(a, try allocPrint(a, "{f}", .{abx.Html{ .text = line }}));
        }
    }

    return .{ found_ref, try std.mem.join(a, "<br />\n", message_lines.items) };
}

const DiffViewPage = Template.PageData("delta-diff.html");

fn view(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;

    const delta_id = f.uri.next().?;
    const idx = isHex(delta_id) orelse return error.Unrouteable;

    var delta = Delta.open(rd.name, idx, f.alloc, f.io) catch |err| switch (err) {
        error.FSFault => return error.ServerFault,
        error.NoSpaceLeft => return error.Unknown,
        error.DeltaDoesNotExist => return error.InvalidURI,
    };

    const revision: ?u64 = if (f.uri.next()) |next| if (eql(u8, next, "rev")) rev: {
        break :rev if (f.uri.next()) |str|
            parseInt(u64, str, 10) catch return error.InvalidURI
        else
            return error.InvalidURI;
    } else return error.Unrouteable else switch (delta.attach) {
        .nos => null,
        .diff => delta.attach_target,
        .issue => {
            var buf: [100]u8 = undefined;
            const loc = try bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, delta.index });
            return f.redirect(loc, .see_other) catch unreachable;
        },
        else => {
            std.debug.print("can't redirect attach {s}\n", .{@tagName(delta.attach)});
            return error.DataInvalid;
        },
    };

    // TODO remove delta_id from call
    return viewDiffRevision(f, &delta, revision, delta_id);
}

fn viewDiffRevision(f: *Frame, delta: *Delta, rev: ?u64, delta_index: []const u8) Error!void {
    // TODO remove delta_index
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;

    if (updatePatchView(f)) |_| return f.redirect(f.request.uri, .see_other) catch unreachable;
    const patch_view_mode = updateFetchPatchView(f) catch .inlined;

    var repo = (repos.open(rd.name, .public, f.io) catch return error.DataInvalid) orelse return error.DataInvalid;
    repo.loadData(f.alloc, f.io) catch return error.ServerFault;
    defer repo.raze(f.alloc, f.io);

    const head_commit = repo.headSha(f.io) catch null;

    var diffM: ?Diff = if (rev) |r|
        Diff.open(r, f.alloc, f.io) catch null
    else
        null;

    // meme saved to protect history
    //for ([_]Comment{ .{
    //    .author = "grayhatter",
    //    .message = "Wow, srctree's Diff view looks really good!",
    //}, .{
    //    .author = "robinli",
    //    .message = "I know, it's clearly the best I've even seen. Soon it'll even look good in Hastur!",
    //} }) |cm| {
    //    comments.pushSlice(addComment(f.alloc, cm) catch unreachable);
    //}

    var patch_formatted: ?S.PatchHtml = null;

    var patch: ?Patch = null;
    const curl_hint: S.DeltaDiffHtml.CurlHint = .{
        .repo_name = rd.name,
        .diff_idx = delta_index,
        .base_ref = if (head_commit) |ref| ref.text().sha1[0..8] else "base_commit",
        .head_ref = "&lt;HEAD&gt;",
        .host = f.request.host orelse "127.0.0.1",
    };
    var applies: bool = false;
    if (diffM) |*diff| {
        if (std.mem.trim(u8, diff.patch.blob, &std.ascii.whitespace).len > 0) {
            patch = .init(diff.patch.blob);
            patch.?.revision = rev;
            if (patchStruct(f.alloc, &patch.?, patch_view_mode)) |phtml| {
                patch_formatted = phtml;
            } else |err| {
                std.debug.print("Unable to generate patch {any}\n", .{err});
            }
            const cmt = repo.headCommit(f.alloc, f.io) catch return error.ServerFault;
            if (eql(u8, &cmt.sha.text().sha1, &diff.applies_hash)) { // FIXME
                applies = diff.applies;
            } else {
                var agent = repo.getAgent(f.alloc);
                if (agent.checkPatch(diff.patch.blob, f.io)) |_| {
                    applies = true;
                    diff.applies = true;
                } else |err| {
                    std.debug.print("git apply failed {any}\n", .{err});
                    diff.applies = false;
                }

                @memcpy(diff.applies_hash[0..40], cmt.sha.text().sha1[0..40]);
                diff.commit(f.io) catch return error.ServerFault;
            }
        }
    }

    const now: i64 = Io.Clock.real.now(f.io).toSeconds();
    const messages = try delta_shared.genThreadMessages(delta, &repo, if (patch) |*p| p else null, f.alloc, f.io);

    const username = if (f.user) |usr| usr.username.? else "public";

    const patch_data: S.DeltaDiffHtml.Patch = .{ .patch = patch_formatted orelse .{ .files = &.{} } };

    const status: []const u8 = if (delta.state.closed)
        "<span class=closed>closed</span>"
    else
        "<span class=open>open</span>";

    var body_header: S.BodyHeaderHtml = .{ .nav = .{ .nav_buttons = &try RepoEndpoint.navButtons(f) } };
    if (f.user) |usr| {
        body_header.nav.nav_auth = usr.username.?;
    }
    var page = DiffViewPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = body_header,
        .repo_header = .{
            .repo_name = rd.name,
            .description = try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = repo.description(f.alloc, f.io) catch "" }}),
            .blame = null,
            .git_uri = null,
            .upstream = null,
        },
        .patch = patch_data,
        .curl_hint = if (diffM == null) curl_hint else null,
        .title = allocPrint(f.alloc, "{f}", .{abx.Html{ .text = delta.title }}) catch unreachable,
        .description = allocPrint(f.alloc, "{f}", .{abx.Html{ .text = delta.message }}) catch unreachable,
        .status = status,
        .created = try allocPrint(f.alloc, "{f}", .{Humanize.unix(delta.created, now)}),
        .updated = try allocPrint(f.alloc, "{f}", .{Humanize.unix(delta.updated, now)}),
        .creator = if (delta.author) |author| try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = author }}) else null,
        .comments = .{ .messages = messages },
        .comment_box = .{
            .current_username = username,
            .delta_id = delta_index,
            .diff_id = try allocPrint(f.alloc, "{}", .{delta.attach_target}),
        },
        .patch_warning = if (applies) null else .{},
        .inline_toggle = if (patch_view_mode == .inlined) .inlined else .split,
    });

    try f.sendPage(&page);
}

const SearchReq = struct {
    q: ?[]const u8,
};

fn list(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;

    const udata = f.request.data.query.validate(SearchReq) catch return error.DataInvalid;
    if (udata.q) |q| {
        var b: [0xFF]u8 = undefined;
        if (find(u8, q, "is:diff") == null or
            find(u8, q, try bufPrint(&b, "repo:{s}", .{rd.name})) == null)
        {
            var buf: [0x2FF]u8 = undefined;
            for (f.request.data.query.bytes) |c| if (!std.ascii.isAscii(c)) return error.Abuse;
            const loc = bufPrint(&buf, "/search?{s}", .{f.request.data.query.bytes}) catch &buf;
            return f.redirect(loc, .see_other) catch unreachable;
        }
    }

    const rules = try search.genRules(udata.q orelse "is:diff", f.alloc);
    var itr = Delta.searchRepo(rd.name, rules.items, f.io);
    var default_search_buf: [0xFF]u8 = undefined;
    const search_str = if (udata.q) |q| allocPrint(f.alloc, "{f}", .{abx.Html{ .text = q }}) catch unreachable else try bufPrint(&default_search_buf, "repo:{s} is:diff", .{rd.name});

    var body_header: S.BodyHeaderHtml = .{ .nav = .{ .nav_buttons = &(endpt_repos.navButtons(f) catch unreachable) } };
    if (f.user) |usr| body_header.nav.nav_auth = usr.username.?;
    f.response_data.add(S.BodyHeaderHtml, f.alloc, &body_header) catch {};

    return delta_shared.list(f, Delta.RepoIterator, &itr, search_str);
}

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const eql = std.mem.eql;
const find = std.mem.find;
const findPos = std.mem.findPos;
const findAnyPos = std.mem.findAnyPos;
const findScalarPos = std.mem.findScalarPos;
const isDigit = std.ascii.isDigit;
const isWhitespace = std.ascii.isWhitespace;
const parseInt = std.fmt.parseInt;
const splitScalar = std.mem.splitScalar;

const RepoEndpoint = @import("../repos.zig");
const RouteData = RepoEndpoint.RouteData;
const updateFetchPatchView = RepoEndpoint.updateFetchPatchView;
const updatePatchView = RepoEndpoint.updatePatchView;
const PatchViewMode = RepoEndpoint.PatchViewMode;

const search = @import("../search.zig");
const delta_shared = @import("../delta.zig");

const verse = @import("verse");
const abx = verse.abx;
const Frame = verse.Frame;
const Error = Route.Error;
const POST = Route.POST;
const ROUTE = Route.ROUTE;
const Template = verse.template;
const HTML = verse.HTML;
const DOM = verse.DOM;

const Git = @import("../../git.zig");
const Highlighting = @import("../../syntax-highlight.zig");
const Humanize = @import("../../humanize.zig");
const repos = @import("../../repos.zig");
const endpt_repos = @import("../repos.zig");
const Patch = @import("../../patch.zig");
const Route = verse.Router;
const S = Template.Structs;
const Types = @import("../../types.zig");
const Delta = Types.Delta;
const Diff = Types.Diff;
