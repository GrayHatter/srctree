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
        .GET => newGET(f),
        .POST => newPOST(f),
        .PUT => newPUT(f),
        else => newGET(f),
    };
}

fn newPUT(f: *Frame) Error!void {
    std.debug.print("new put {any}\n", .{f.request.data});
    return newGET(f);
}

fn newPOST(f: *Frame) Error!void {
    // TODO implementent
    return newGET(f);
}

fn newGET(f: *Frame) Error!void {
    var patch_network: ?S.PatchNetwork = null;
    var patch_uri: ?S.PatchUri = null;
    var patch_paste: ?S.PatchPaste = null;
    var patch_curl: ?S.PatchCurl = null;
    var title: ?[]const u8 = null;
    var desc: ?[]const u8 = null;

    const routing_data = RouteData.init(f.uri) orelse return error.Unrouteable;
    var repo = (Repos.open(routing_data.name, .public, f.io) catch return error.DataInvalid) orelse return error.DataInvalid;
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
            const network_remotes = try f.alloc.alloc(S.Remotes, remotes.len);
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

fn newComment(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    var buf: [2048]u8 = undefined;
    if (f.request.data.post) |post| {
        var valid = post.validator();
        const delta_id = try valid.require("did");
        const delta_index = isHex(delta_id.value) orelse return error.Unrouteable;
        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/diff/{x}", .{ rd.name, delta_index });

        const msg = try valid.require("comment");
        if (msg.value.len < 2) return f.redirect(loc, .see_other) catch unreachable;

        var delta = Delta.open(rd.name, delta_index, f.alloc, f.io) catch return error.Unknown;
        const username = if (f.user) |usr| usr.username.? else "public";
        delta.addComment(.{ .author = username, .message = msg.value }, f.alloc, f.io) catch unreachable;
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

pub fn patchStruct(a: Allocator, patch: *Patch, unified: bool) !Template.Structs.PatchHtml {
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
    const files = try a.alloc(Template.Structs.Files, diffs.len);
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
        if (unified) {
            const split = try Patch.diffLineHtmlSplit(a, body);
            var lines_left: ArrayList([]u8) = .{};
            var lines_right: ArrayList([]u8) = .{};
            for (split.left) |left| try lines_left.append(a, switch (left) {
                .hdr => |hdr| try allocPrint(a, "<div class=\"block\">{s}</div>", .{hdr}),
                .add => |add| try allocPrint(
                    a,
                    "<div class=\"add\"><ln num=\"{0d}\" id=\"LL{0d}\" href=\"#LL{0d}\">{1s}</ln></div>",
                    .{ add.number, add.text },
                ),
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
                .empty => try allocPrint(a, "<div class=\"nul\"></div>", .{}),
            });
            for (split.right) |right| try lines_right.append(a, switch (right) {
                .hdr => |hdr| try allocPrint(a, "<div class=\"block\">{s}</div>", .{hdr}),
                .add => |add| try allocPrint(
                    a,
                    "<div class=\"add\"><ln num=\"{0d}\" id=\"RL{0d}\" href=\"#RL{0d}\">{1s}</ln></div>",
                    .{ add.number, add.text },
                ),
                .del => |del| try allocPrint(
                    a,
                    "<div class=\"del\"><ln num=\"{0d}\" id=\"RL{0d}\" href=\"#RL{0d}\">{1s}</ln></div>",
                    .{ del.number, del.text },
                ),
                .ctx => |ctx| try allocPrint(
                    a,
                    "<div><ln num=\"{0d}\" id=\"RL{0d}\" href=\"#RL{0d}\">{1s}</ln></div>",
                    .{ ctx.number, ctx.text },
                ),
                .empty => try allocPrint(a, "<div class=\"nul\"></div>", .{}),
            });
            file.*.patch_split = .{
                .diff_lines_left = try lines_left.toOwnedSlice(a),
                .diff_lines_right = try lines_right.toOwnedSlice(a),
            };
        } else {
            var lines: ArrayList([]u8) = .{};
            for (try Patch.diffLineHtmlUnified(a, body)) |line| {
                try lines.append(a, switch (line) {
                    .hdr => |hdr| try allocPrint(a, "<div class=\"block\">{s}</div>", .{hdr}),
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
                    .empty => unreachable,
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

fn getLineAt(data: []const u8, target: u32, length: u32, right_only: bool) !?[]const u8 {
    std.debug.assert(length == 1); // Not Implemented
    var itr = splitScalar(u8, data, '\n');
    const header = try parseBlockHeader(itr.next().?);
    var i: usize = header.right.start;
    while (itr.next()) |line| {
        if (line.len == 0) @panic("unexpected line length");
        switch (line[0]) {
            '-' => {
                if (!right_only) {
                    if (i == target) return line;
                    i += 1;
                }
            },
            '+' => {
                if (right_only) {
                    if (i == target) return line;
                    i += 1;
                }
            },
            ' ' => {
                if (i == target) return line;
                i += 1;
            },
            else => {},
        }
    }
    return null;
}

/// TODO move to patch.zig
fn parseBlockHeader(string: []const u8) !ParsedHeader {
    const end = indexOf(u8, string[3..], " @@") orelse return error.InvalidBlockHeader;
    const offsets = string[3 .. end + 3];
    const mid = indexOf(u8, offsets, " ") orelse unreachable;
    const left = offsets[1..mid];
    const right = offsets[mid + 2 ..];
    const left_mid = indexOf(u8, left, ",") orelse unreachable;
    const l_low = try parseInt(u32, left[0..left_mid], 10);
    const l_high = try parseInt(u32, left[left_mid + 1 ..], 10);
    const right_mid = indexOf(u8, right, ",") orelse unreachable;
    const r_low = try parseInt(u32, right[0..right_mid], 10);
    const r_high = try parseInt(u32, right[right_mid + 1 ..], 10);
    return .{
        .left = .{ .start = l_low, .change = l_high },

        .right = .{ .start = r_low, .change = r_high },
    };
}

fn resolveLineRefRepo(
    line: []const u8,
    filename: []const u8,
    repo: *const Git.Repo,
    line_number: u32,
    line_stride: ?u32,
    a: Allocator,
    io: Io,
) !?[][]const u8 {
    var found_lines: ArrayList([]const u8) = .{};

    const cmt = try repo.headCommit(a, io);
    var files: Git.Tree = try cmt.loadTree(repo, a, io);
    var itr = splitScalar(u8, filename, '/');
    const blob_sha: Git.SHA = root: while (itr.next()) |dirname| {
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
    var count: usize = line_number;
    var stride: usize = (line_stride orelse line_number) - line_number;
    while (indexOfScalarPos(u8, file.data.?, @max(end, start) + 1, '\n')) |next| {
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
    const formatted = if (found_line.len == 0)
        "&nbsp;"
    else if (Highlighting.Language.guessFromFilename(filename)) |lang|
        try Highlighting.highlight(a, lang, found_line[1..])
    else
        try allocPrint(a, "{f}", .{abx.Html{ .text = found_line[1..] }});

    const wrapped_line = try allocPrint(
        a,
        "<div title=\"{s}\" class=\"coderef\">{s}</div>",
        .{ try allocPrint(a, "{f}", .{abx.Html{ .text = line }}), formatted },
    );
    try found_lines.append(a, wrapped_line);
    return try found_lines.toOwnedSlice(a);
}

fn resolveLineRefDiff(
    a: Allocator,
    line: []const u8,
    filename: []const u8,
    diff: *Patch.Diff,
    line_number: u32,
    line_stride: ?u32,
    fpos: usize,
) !?[][]const u8 {
    _ = line_stride;
    const side: ?Side = if (fpos > 0)
        switch (line[fpos - 1]) {
            '+' => .add,
            '-' => .del,
            else => null,
        }
    else
        null;
    var found_lines: ArrayList([]const u8) = .{};
    const blocks = try diff.blocksAlloc(a);
    for (blocks) |block| {
        const change = try parseBlockHeader(block);
        const in_left = line_number >= change.left.start and line_number <= change.left.start + change.left.change;
        const in_right = line_number >= change.right.start and line_number <= change.right.start + change.right.change;
        if (in_left or in_right) {
            const sided: bool = if (side) |s| if (s == .add) true else false else true;
            if (try getLineAt(block, line_number, 1, sided)) |found_line| {
                const color = switch (found_line[0]) {
                    '+' => "green",
                    '-' => "red",
                    ' ' => "yellow",
                    else => "error",
                };
                const formatted = if (found_line.len <= 1)
                    "&nbsp;"
                else if (Highlighting.Language.guessFromFilename(filename)) |lang|
                    try Highlighting.highlight(a, lang, found_line[1..])
                else
                    try allocPrint(a, "{f}", .{abx.Html{ .text = found_line[1..] }});

                const wrapped_line = try allocPrint(
                    a,
                    "<div title=\"{s}\" class=\"coderef {s}\">{s}</div>",
                    .{ try allocPrint(a, "{f}", .{abx.Html{ .text = line }}), color, formatted },
                );
                try found_lines.append(a, wrapped_line);
            }
            break;
        }
    } else return null;
    return try found_lines.toOwnedSlice(a);
}

fn lineNumberStride(target: []const u8) !struct { u32, ?u32 } {
    std.debug.assert(target.len > 1);
    switch (target[0]) {
        '#', ':', '@' => {
            var search_end: usize = 1;
            while (search_end < target.len and
                isDigit(target[search_end]))
            {
                search_end += 1;
            }
            var stride: ?u32 = null;
            if (target.len > search_end) {
                switch (target[search_end]) {
                    '-' => {
                        const stride_start = search_end + 1;
                        var stride_end = stride_start;
                        while (stride_end < target.len and isDigit(target[stride_end])) {
                            stride_end += 1;
                        }
                        stride = parseInt(u32, target[stride_start..stride_end], 10) catch null;
                    },
                    '+' => unreachable, // not implemented
                    else => {},
                }
            }

            const search = try parseInt(u32, target[1..search_end], 10);
            return .{ search, stride };
        },
        else => return error.InvalidSpecifier,
    }
    return error.InvalidLineTarget;
}

test lineNumberStride {
    const left, const missing = try lineNumberStride("#10");
    try std.testing.expectEqual(10, left);
    try std.testing.expectEqual(null, missing);

    const left_, const right = try lineNumberStride("#10-20");
    try std.testing.expectEqual(10, left_);
    try std.testing.expectEqual(20, right);
}

const FileLineRef = struct {
    file: []const u8,
    line: u32,
    stride: ?u32,
};

fn fileLineRef(str: []const u8) ?FileLineRef {
    var w_start: usize = 0;

    while (w_start + 3 < str.len) {
        w_start = indexOfAnyPos(u8, str, w_start, "/.") orelse return null;
        var file_start = w_start;
        while (file_start > 0 and str[file_start] != ' ') file_start -= 1;
        if (str[file_start] == ' ') file_start += 1;

        if (indexOfAnyPos(u8, str, w_start, " #:@")) |loc| {
            w_start = loc;
            if (str[loc] == ' ') continue;
            const line, const stride = lineNumberStride(str[loc..]) catch return null;
            return .{
                .file = str[file_start..loc],
                .line = line,
                .stride = stride,
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
        FileLineRef{ .file = "src/main.zig", .line = 12, .stride = null },
        fileLineRef("src/main.zig#12").?,
    );
    try std.testing.expectEqualDeep(
        FileLineRef{ .file = "src/main.zig", .line = 12, .stride = null },
        fileLineRef("src/main.zig:12").?,
    );
    try std.testing.expectEqualDeep(
        FileLineRef{ .file = "src/main.zig", .line = 12, .stride = null },
        fileLineRef("src/main.zig@12").?,
    );

    try std.testing.expectEqualDeep(
        FileLineRef{ .file = "src/srctree.zig", .line = 13, .stride = null },
        fileLineRef("some before text src/srctree.zig#13 and some after text").?,
    );

    try std.testing.expectEqualDeep(
        FileLineRef{ .file = "main.zig", .line = 14, .stride = null },
        fileLineRef("main.zig#14").?,
    );
    try std.testing.expectEqualDeep(
        FileLineRef{ .file = "src/main", .line = 15, .stride = null },
        fileLineRef("src/main#15").?,
    );
}

const Side = enum { del, add };
fn translateComment(comment: []const u8, patch: Patch, repo: *const Git.Repo, a: Allocator, io: Io) ![]u8 {
    var message_lines: ArrayList([]const u8) = .{};
    defer message_lines.clearAndFree(a);

    var itr = splitScalar(u8, comment, '\n');
    while (itr.next()) |line_| {
        const line = std.mem.trim(u8, line_, "\r ");
        const diffs: []Patch.Diff = patch.diffs orelse &.{};
        for (diffs) |*diff| {
            const filename = diff.filename orelse continue;
            //std.debug.print("files {s}\n", .{filename});
            if (indexOf(u8, line, filename)) |filepos| {
                if (indexOfAny(u8, line, "#:@")) |h| {
                    const left, const right = try lineNumberStride(line[h..]);

                    if (try resolveLineRefDiff(a, line, filename, diff, left, right, filepos)) |lines| {
                        try message_lines.appendSlice(a, lines);
                        var end: usize = h;
                        while (end < line.len and !isWhitespace(line[end])) {
                            end += 1;
                        }
                        if (end < line.len) try message_lines.append(
                            a,
                            try allocPrint(a, "{f}", .{abx.Html{ .text = line[end..] }}),
                        );
                    } else if (resolveLineRefRepo(line, filename, repo, left, right, a, io) catch |err| switch (err) {
                        error.LineNotFound => null,
                        else => return err,
                    }) |lines| {
                        try message_lines.appendSlice(a, lines);
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

    return try std.mem.join(a, "<br />\n", message_lines.items);
}

const DiffViewPage = Template.PageData("delta-diff.html");

fn view(f: *Frame) Error!void {
    const now: i64 = (Io.Clock.now(.real, f.io) catch unreachable).toSeconds();
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;

    const delta_id = f.uri.next().?;
    const idx = isHex(delta_id) orelse return error.Unrouteable;

    var repo = (Repos.open(rd.name, .public, f.io) catch return error.DataInvalid) orelse return error.DataInvalid;
    repo.loadData(f.alloc, f.io) catch return error.ServerFault;
    defer repo.raze(f.alloc, f.io);

    var delta = Delta.open(rd.name, idx, f.alloc, f.io) catch |err| switch (err) {
        //error.InvalidTarget => return error.Unrouteable,
        //error.InputOutput => unreachable,
        //error.Other => unreachable,
        else => unreachable,
    };

    var diffM: ?Diff = null;
    switch (delta.attach) {
        .nos => {},
        .diff => diffM = Diff.open(delta.attach_target, f.alloc, f.io) catch return error.Unknown,
        .issue => {
            var buf: [100]u8 = undefined;
            const loc = try bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, delta.index });
            return f.redirect(loc, .see_other) catch unreachable;
        },
        else => {
            std.debug.print("can't redirect attach {s}\n", .{@tagName(delta.attach)});
            return error.DataInvalid;
        },
    }

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

    const inline_html: bool = getAndSavePatchView(f);

    var patch_formatted: ?S.PatchHtml = null;
    //const patch_filename = try std.fmt.allocPrint(f.alloc, "data/patch/{s}.{x}.patch", .{ rd.name, delta.index });

    var patch: ?Patch = null;
    var curl_hint: ?S.CurlHint = null;
    var applies: bool = false;
    if (diffM) |*diff| {
        if (std.mem.trim(u8, diff.patch.blob, &std.ascii.whitespace).len > 0) {
            patch = .init(diff.patch.blob);
            if (patchStruct(f.alloc, &patch.?, !inline_html)) |phtml| {
                patch_formatted = phtml;
            } else |err| {
                std.debug.print("Unable to generate patch {any}\n", .{err});
            }
            const cmt = repo.headCommit(f.alloc, f.io) catch return error.ServerFault;
            if (eql(u8, &cmt.sha.hex(), &diff.applies_hash)) {
                applies = diff.applies;
            } else {
                var agent = repo.getAgent(f.alloc);
                if (agent.checkPatch(diff.patch.blob)) |_| {
                    applies = true;
                    diff.applies = true;
                } else |err| {
                    std.debug.print("git apply failed {any}\n", .{err});
                    diff.applies = false;
                }

                @memcpy(diff.applies_hash[0..40], cmt.sha.hex()[0..40]);
                diff.commit(f.io) catch return error.ServerFault;
            }
        } else {
            curl_hint = .{
                .repo_name = rd.name,
                .diff_idx = delta_id,
                .host = f.request.host orelse "127.0.0.1",
            };
        }
    }

    var root_thread: []S.Thread = &.{};
    if (delta.loadThread(f.alloc, f.io)) |thread| {
        root_thread = try f.alloc.alloc(S.Thread, thread.messages.items.len);
        var cmt_diff = diffM;
        for (thread.messages.items, root_thread) |msg, *c_ctx| {
            switch (msg.kind) {
                .comment => {
                    var comment_patch: ?Patch = patch;
                    if (cmt_diff) |cd| {
                        if (cd.index != msg.extra0) {
                            cmt_diff = Diff.open(msg.extra0, f.alloc, f.io) catch cd;
                            comment_patch = .init(cmt_diff.?.patch.blob);
                        }
                    }

                    if (comment_patch) |*cp| if (cp.diffs == null) cp.parse(f.alloc) catch {};
                    c_ctx.* = .{
                        .author = try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = msg.author.? }}),
                        .date = try allocPrint(f.alloc, "{f}", .{Humanize.unix(msg.updated, now)}),
                        .message = if (comment_patch) |pt|
                            translateComment(msg.message.?, pt, &repo, f.alloc, f.io) catch unreachable
                        else
                            try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = msg.message.? }}),
                        .direct_reply = .{ .uri = try allocPrint(f.alloc, "{}/direct_reply/{x}", .{
                            idx,
                            msg.hash[0..],
                        }) },
                        .sub_thread = null,
                    };
                },
                .diff_update => {
                    c_ctx.* = .{
                        .author = try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = msg.author.? }}),
                        .date = try allocPrint(f.alloc, "{f}", .{Humanize.unix(msg.updated, now)}),
                        .message = msg.message.?,
                        .direct_reply = null,
                        .sub_thread = null,
                    };
                },
                //else => {
                //    c_ctx.* = .{
                //        .author = "",
                //        .date = "",
                //        .message = "unsupported message type",
                //        .direct_reply = null,
                //        .sub_thread = null,
                //    };
                //},
            }
        }
    } else |err| {
        std.debug.print("Unable to load comments for thread {} {}\n", .{ idx, err });
        @panic("oops");
    }

    const username = if (f.user) |usr| usr.username.? else "public";

    const patch_data: S.Patch = .{ .patch = patch_formatted orelse .{ .files = &.{} } };

    const status: []const u8 = if (delta.closed)
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
        .patch = patch_data,
        .curl_hint = curl_hint,
        .title = allocPrint(f.alloc, "{f}", .{abx.Html{ .text = delta.title }}) catch unreachable,
        .description = allocPrint(f.alloc, "{f}", .{abx.Html{ .text = delta.message }}) catch unreachable,
        .status = status,
        .created = try allocPrint(f.alloc, "{f}", .{Humanize.unix(delta.created, now)}),
        .updated = try allocPrint(f.alloc, "{f}", .{Humanize.unix(delta.updated, now)}),
        .creator = if (delta.author) |author| try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = author }}) else null,
        .comments = .{ .thread = root_thread },
        .delta_id = delta_id,
        .patch_warning = if (applies) null else .{},
        .current_username = username,
    });

    try f.sendPage(&page);
}

const SearchReq = struct {
    q: ?[]const u8,
};

const DeltaListPage = Template.PageData("delta-list.html");
fn list(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;

    const udata = f.request.data.query.validate(SearchReq) catch return error.DataInvalid;
    if (udata.q) |q| {
        var b: [0xFF]u8 = undefined;
        if (indexOf(u8, q, "is:diff") == null or
            indexOf(u8, q, try bufPrint(&b, "repo:{s}", .{rd.name})) == null)
        {
            var buf: [0x2FF]u8 = undefined;
            for (f.request.data.query.rawquery) |c| if (!std.ascii.isAscii(c)) return error.Abuse;
            const loc = bufPrint(&buf, "/search?{s}", .{f.request.data.query.rawquery}) catch &buf;
            return f.redirect(loc, .see_other) catch unreachable;
        }
    }

    var rules: ArrayList(Delta.SearchRule) = .{};
    {
        var itr = splitScalar(u8, udata.q orelse "", ' ');
        while (itr.next()) |r_line| {
            var line = r_line;
            line = std.mem.trim(u8, line, " ");
            if (line.len == 0) continue;
            try rules.append(f.alloc, .parse(line));
        }
    }

    var d_list: ArrayList(S.DeltaList) = .{};
    var itr = Delta.searchRepo(rd.name, rules.items, f.io);
    const uri_base = try allocPrint(f.alloc, "/repo/{s}/diffs", .{rd.name});
    while (itr.next(f.alloc, f.io)) |deltaC| {
        var d = deltaC;
        if (d.attach != .diff) continue;
        if (d.closed) continue;

        _ = d.loadThread(f.alloc, f.io) catch unreachable;
        const cmtsmeta = d.countComments(f.io);
        try d_list.append(f.alloc, .{
            .index = try allocPrint(f.alloc, "{x}", .{d.index}),
            .uri_base = uri_base[0 .. uri_base.len - 1],
            .title = try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = d.title }}),
            .comment_new = if (cmtsmeta.new) " new" else "",
            .comment_count = cmtsmeta.count,
            .desc = try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = d.message }}),
            .delta_meta = null,
        });
    }

    var default_search_buf: [0xFF]u8 = undefined;
    const search_str = if (udata.q) |q| allocPrint(f.alloc, "{f}", .{abx.Html{ .text = q }}) catch unreachable else try bufPrint(&default_search_buf, "repo:{s} is:diff", .{rd.name});
    var body_header: S.BodyHeaderHtml = .{ .nav = .{ .nav_buttons = &try RepoEndpoint.navButtons(f) } };
    if (f.user) |usr| {
        body_header.nav.nav_auth = usr.username.?;
    }
    var page = DeltaListPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = body_header,
        .search_action = uri_base,
        .delta_list = d_list.items,
        .search = search_str,
    });

    return try f.sendPage(&page);
}

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const indexOfAny = std.mem.indexOfAny;
const indexOfAnyPos = std.mem.indexOfAnyPos;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const isDigit = std.ascii.isDigit;
const isWhitespace = std.ascii.isWhitespace;
const parseInt = std.fmt.parseInt;
const splitScalar = std.mem.splitScalar;

const RepoEndpoint = @import("../repos.zig");
const RouteData = RepoEndpoint.RouteData;
const getAndSavePatchView = RepoEndpoint.getAndSavePatchView;

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
const Repos = @import("../../repos.zig");
const Patch = @import("../../patch.zig");
const Route = verse.Router;
const S = Template.Structs;
const Types = @import("../../types.zig");
const Delta = Types.Delta;
const Diff = Types.Diff;
