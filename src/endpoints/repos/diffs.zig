pub const routes = [_]Route.Match{
    ROUTE("", list),
    ROUTE("new", new),
    POST("create", createDiff),
    POST("add-comment", newComment),
};

fn isHex(input: []const u8) ?usize {
    for (input) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return std.fmt.parseInt(usize, input, 16) catch null;
}

pub fn router(ctx: *Frame) Route.RoutingError!Route.BuildFn {
    if (!eql(u8, "diffs", ctx.uri.next() orelse return error.Unrouteable))
        return error.Unrouteable;
    const verb = ctx.uri.peek() orelse return Route.defaultRouter(ctx, &routes);

    if (isHex(verb)) |_| {
        const uri_save = ctx.uri.index;
        defer ctx.uri.index = uri_save;
        _ = ctx.uri.next();
        if (ctx.uri.peek()) |action| {
            if (eql(u8, action, "direct_reply")) return directReply;
        }

        return view;
    }

    return Route.defaultRouter(ctx, &routes);
}

const DiffNewHtml = Template.PageData("diff-new.html");

const DiffCreateChangeReq = struct {
    from_network: ?bool = null,
    patch_uri: []const u8,
    title: []const u8,
    desc: []const u8,
};

fn new(ctx: *Frame) Error!void {
    var network: ?S.Network = null;
    var patchuri: ?S.PatchUri = .{};
    var title: ?[]const u8 = null;
    var desc: ?[]const u8 = null;
    if (ctx.request.data.post) |post| {
        const udata = post.validate(DiffCreateChangeReq) catch return error.DataInvalid;
        title = udata.title;
        desc = udata.desc;

        if (udata.from_network) |_| {
            const rd = RouteData.init(ctx.uri) orelse return error.Unrouteable;
            var cwd = std.fs.cwd();
            const filename = try allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
            const dir = cwd.openDir(filename, .{}) catch return error.Unknown;
            var repo = Git.Repo.init(dir) catch return error.Unrouteable;
            defer repo.raze();
            repo.loadData(ctx.alloc) catch return error.Unknown;

            const remotes = repo.remotes orelse unreachable;
            defer {
                for (remotes) |r| r.raze(ctx.alloc);
                ctx.alloc.free(remotes);
            }

            const network_remotes = try ctx.alloc.alloc(S.Remotes, remotes.len);
            for (remotes, network_remotes) |src, *dst| {
                dst.* = .{
                    .value = src.name,
                    .name = try allocPrint(ctx.alloc, "{diff}", .{src}),
                };
            }

            network = .{
                .remotes = network_remotes,
                .branches = &.{
                    .{ .value = "main", .name = "main" },
                    .{ .value = "develop", .name = "develop" },
                    .{ .value = "master", .name = "master" },
                },
            };
        }
        patchuri = null;
    }

    var page = DiffNewHtml.init(.{
        .meta_head = .{
            .open_graph = .{},
        },
        .body_header = .{ .nav = .{
            .nav_buttons = &try Repos.navButtons(ctx),
        } },
        .title = title,
        .desc = desc,
        .network = network,
        .patch_uri = patchuri,
    });

    try ctx.sendPage(&page);
}

fn inNetwork(str: []const u8) bool {
    //if (!std.mem.startsWith(u8, str, "https://srctree.gr.ht")) return false;
    //for (str) |c| if (c == '@') return false;
    _ = str;
    return true;
}

const DiffCreateReq = struct {
    patch_uri: []const u8,
    title: []const u8,
    desc: []const u8,
    //action: ?union(enum) {
    //    submit: bool,
    //    preview: bool,
    //},
};

fn createDiff(vrs: *Frame) Error!void {
    const rd = RouteData.init(vrs.uri) orelse return error.Unrouteable;
    if (vrs.request.data.post) |post| {
        const udata = post.validate(DiffCreateReq) catch return error.DataInvalid;
        if (udata.title.len == 0) return error.DataInvalid;

        var remote_addr: []const u8 = "unknown";
        remote_addr = vrs.request.remote_addr;

        if (inNetwork(udata.patch_uri)) {
            const data = Patch.loadRemote(vrs.alloc, udata.patch_uri) catch unreachable;

            std.debug.print(
                "src {s}\ntitle {s}\ndesc {s}\naction {s}\n",
                .{ udata.patch_uri, udata.title, udata.desc, "unimplemented" },
            );
            var delta = Delta.new(
                rd.name,
                udata.title,
                udata.desc,
                if (vrs.user) |usr| usr.username.? else try allocPrint(vrs.alloc, "REMOTE_ADDR {s}", .{remote_addr}),
            ) catch unreachable;
            delta.commit() catch unreachable;
            std.debug.print("commit id {x}\n", .{delta.index});

            const filename = allocPrint(vrs.alloc, "data/patch/{s}.{x}.patch", .{
                rd.name,
                delta.index,
            }) catch unreachable;
            var file = std.fs.cwd().createFile(filename, .{}) catch unreachable;
            defer file.close();
            file.writer().writeAll(data.blob) catch unreachable;
            var buf: [2048]u8 = undefined;
            const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/diffs/{x}", .{ rd.name, delta.index });
            return vrs.redirect(loc, .see_other) catch unreachable;
        }
    }

    return try new(vrs);
}

fn newComment(ctx: *Frame) Error!void {
    const rd = RouteData.init(ctx.uri) orelse return error.Unrouteable;
    var buf: [2048]u8 = undefined;
    if (ctx.request.data.post) |post| {
        var valid = post.validator();
        const delta_id = try valid.require("did");
        const delta_index = isHex(delta_id.value) orelse return error.Unrouteable;
        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/diffs/{x}", .{ rd.name, delta_index });

        const msg = try valid.require("comment");
        if (msg.value.len < 2) return ctx.redirect(loc, .see_other) catch unreachable;

        var delta = Delta.open(ctx.alloc, rd.name, delta_index) catch unreachable orelse return error.Unrouteable;
        const username = if (ctx.user) |usr| usr.username.? else "public";
        var thread = delta.loadThread(ctx.alloc) catch unreachable;
        thread.newComment(ctx.alloc, .{ .author = username, .message = msg.value }) catch unreachable;
        // TODO record current revision at comment time
        delta.commit() catch unreachable;
        return ctx.redirect(loc, .see_other) catch unreachable;
    }
    return error.Unknown;
}

pub fn directReply(ctx: *Frame) Error!void {
    _ = ctx.uri.next().?;
    _ = ctx.uri.next().?;
    std.debug.print("{s}\n", .{ctx.uri.next().?});
    return error.Unknown;
}

pub fn patchStruct(a: Allocator, patch: *Patch.Patch, unified: bool) !Template.Structs.PatchHtml {
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
        const html_lines = if (unified)
            try Patch.diffLineHtmlSplit(a, body)
        else
            Patch.diffLineHtmlUnified(a, body);
        const diff_lines = try a.alloc([]u8, html_lines.len);
        for (diff_lines, html_lines) |*dline, hline| {
            dline.* = try allocPrint(a, "{}", .{hline});
        }
        file.* = .{
            .diff_stat = stat,
            .filename = if (diff.filename) |name|
                try allocPrint(a, "{s}", .{name})
            else
                try allocPrint(a, "{s} was Deleted", .{"filename"}),
            .diff_lines = diff_lines,
        };
    }
    return .{
        .files = files,
    };
}

pub fn patchHtml(a: Allocator, patch: *Patch.Patch) ![]HTML.Element {
    patch.parse(a) catch |err| {
        if (std.mem.indexOf(u8, patch.blob, "\nMerge: ") == null) {
            std.debug.print("err: {any}\n", .{err});
            std.debug.print("'''\n{s}\n'''\n", .{patch.blob});
            return err;
        } else {
            std.debug.print("Unable to parse diff {} (merge commit)\n", .{err});
            return &[0]HTML.Element{};
        }
    };

    const diffs = patch.diffs orelse unreachable;

    var dom = DOM.new(a);

    dom = dom.open(HTML.patch());
    for (diffs) |diff| {
        const body = diff.changes orelse continue;

        const dstat = patch.patchStat();
        const stat = try std.fmt.allocPrint(
            a,
            "added: {}, removed: {}, total {}",
            .{ dstat.additions, dstat.deletions, dstat.total },
        );
        dom.push(HTML.element("diffstat", stat, null));
        dom = dom.open(HTML.diff());

        dom.push(HTML.element(
            "filename",
            if (diff.filename) |name|
                try std.fmt.allocPrint(a, "{s}", .{name})
            else
                try std.fmt.allocPrint(a, "{s} was Deleted", .{"filename"}),
            null,
        ));
        dom = dom.open(HTML.element("changes", null, null));
        dom.pushSlice(Patch.diffLineHtml(a, body));
        dom = dom.close();
        dom = dom.close();
    }
    dom = dom.close();
    return dom.done();
}

pub const PatchView = struct {
    @"inline": ?bool = true,
};

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
    a: Allocator,
    line: []const u8,
    filename: []const u8,
    repo: *const Git.Repo,
    line_number: u32,
    line_stride: ?u32,
) !?[][]const u8 {
    var found_lines = std.ArrayList([]const u8).init(a);

    const cmt = try repo.headCommit(a);
    var files: Git.Tree = try cmt.loadTree(a, repo);
    var blob_sha: Git.SHA = undefined;
    var itr = splitScalar(u8, filename, '/');
    root: while (itr.next()) |dirname| {
        for (files.blobs) |obj| {
            if (eql(u8, obj.name, dirname)) {
                if (obj.isFile()) {
                    if (itr.peek() != null) return error.InvalidFile;
                    blob_sha = obj.sha;
                    break :root;
                }
                files = try obj.toTree(a, repo);
                continue :root;
            }
        } else {
            std.debug.print("unable to resolve file {s} at {s}\n", .{ filename, dirname });
        }
    }

    var file = try repo.loadBlob(a, blob_sha);
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
    else if (Highlighting.Language.guessFromFilename(filename)) |lang| fmt: {
        var pre = try Highlighting.highlight(a, lang, found_line[1..]);
        break :fmt pre[28..][0 .. pre.len - 41];
    } else try abx.Html.cleanAlloc(a, found_line[1..]);

    const wrapped_line = try allocPrint(
        a,
        "<div title=\"{s}\" class=\"coderef\">{s}</div>",
        .{ try abx.Html.cleanAlloc(a, line), formatted },
    );
    try found_lines.append(wrapped_line);
    return try found_lines.toOwnedSlice();
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
    var found_lines = std.ArrayList([]const u8).init(a);
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
                else if (Highlighting.Language.guessFromFilename(filename)) |lang| fmt: {
                    var pre = try Highlighting.highlight(a, lang, found_line[1..]);
                    break :fmt pre[28..][0 .. pre.len - 41];
                } else try abx.Html.cleanAlloc(a, found_line[1..]);

                const wrapped_line = try allocPrint(
                    a,
                    "<div title=\"{s}\" class=\"coderef {s}\">{s}</div>",
                    .{ try abx.Html.cleanAlloc(a, line), color, formatted },
                );
                try found_lines.append(wrapped_line);
            }
            break;
        }
    } else return null;
    return try found_lines.toOwnedSlice();
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
    const a = try lineNumberStride("#10");
    try std.testing.expectEqual(10, a[0]);
    try std.testing.expectEqual(null, a[1]);

    const b = try lineNumberStride("#10-20");
    try std.testing.expectEqual(10, b[0]);
    try std.testing.expectEqual(20, b[1]);
}

const Side = enum { del, add };
fn translateComment(a: Allocator, comment: []const u8, patch: Patch, repo: *const Git.Repo) ![]u8 {
    var message_lines = std.ArrayList([]const u8).init(a);
    defer message_lines.clearAndFree();

    var itr = splitScalar(u8, comment, '\n');
    while (itr.next()) |line_| {
        // Windows can eat a dick
        const line = std.mem.trim(u8, line_, "\r ");
        for (patch.diffs.?) |*diff| {
            const filename = diff.filename orelse continue;
            //std.debug.print("files {s}\n", .{filename});
            if (indexOf(u8, line, filename)) |filepos| {
                if (indexOfAny(u8, line, "#:@")) |h| {
                    const linenums = try lineNumberStride(line[h..]);

                    if (try resolveLineRefDiff(
                        a,
                        line,
                        filename,
                        diff,
                        linenums[0],
                        linenums[1],
                        filepos,
                    )) |lines| {
                        try message_lines.appendSlice(lines);
                        var end: usize = h;
                        while (end < line.len and !isWhitespace(line[end])) {
                            end += 1;
                        }
                        if (end < line.len) try message_lines.append(
                            try abx.Html.cleanAlloc(a, line[end..]),
                        );
                    } else if (resolveLineRefRepo(
                        a,
                        line,
                        filename,
                        repo,
                        linenums[0],
                        linenums[1],
                    ) catch |err| switch (err) {
                        error.InvalidFile => null,
                        error.LineNotFound => null,
                        else => return err,
                    }) |lines| {
                        try message_lines.appendSlice(lines);
                    } else {
                        try message_lines.append(try allocPrint(
                            a,
                            "<span title=\"line not found in this diff\">{s}</span>",
                            .{try abx.Html.cleanAlloc(a, line)},
                        ));
                    }
                }
                break;
            }
        } else {
            try message_lines.append(try abx.Html.cleanAlloc(a, line));
        }
    }

    return try std.mem.join(a, "<br />\n", message_lines.items);
}

const DiffViewPage = Template.PageData("delta-diff.html");

fn view(ctx: *Frame) Error!void {
    const rd = RouteData.init(ctx.uri) orelse return error.Unrouteable;

    var cwd = std.fs.cwd();
    const filename = try allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    const dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = Git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;
    defer repo.raze();

    const delta_id = ctx.uri.next().?;
    const index = isHex(delta_id) orelse return error.Unrouteable;

    var delta = Delta.open(ctx.alloc, rd.name, index) catch |err| switch (err) {
        error.InvalidTarget => return error.Unrouteable,
        error.InputOutput => unreachable,
        error.Other => unreachable,
        else => unreachable,
    } orelse return error.Unrouteable;

    const patch_header = S.Header{
        .title = abx.Html.cleanAlloc(ctx.alloc, delta.title) catch unreachable,
        .message = abx.Html.cleanAlloc(ctx.alloc, delta.message) catch unreachable,
    };

    // meme saved to protect history
    //for ([_]Comment{ .{
    //    .author = "grayhatter",
    //    .message = "Wow, srctree's Diff view looks really good!",
    //}, .{
    //    .author = "robinli",
    //    .message = "I know, it's clearly the best I've even seen. Soon it'll even look good in Hastur!",
    //} }) |cm| {
    //    comments.pushSlice(addComment(ctx.alloc, cm) catch unreachable);
    //}

    _ = delta.loadThread(ctx.alloc) catch unreachable;

    const udata = ctx.request.data.query.validate(PatchView) catch return error.DataInvalid;
    const inline_html = udata.@"inline" orelse true;

    var patch_formatted: ?Template.Structs.PatchHtml = null;
    const patch_filename = try std.fmt.allocPrint(ctx.alloc, "data/patch/{s}.{x}.patch", .{ rd.name, delta.index });
    var patch_applies: bool = false;
    var patch: ?Patch.Patch = null;
    if (std.fs.cwd().openFile(patch_filename, .{})) |f| {
        const fdata = f.readToEndAlloc(ctx.alloc, 0xFFFFF) catch return error.Unknown;
        patch = Patch.Patch.init(fdata);
        if (patchStruct(ctx.alloc, &patch.?, !inline_html)) |phtml| {
            patch_formatted = phtml;
        } else |err| {
            std.debug.print("Unable to generate patch {any}\n", .{err});
        }
        f.close();

        var agent = repo.getAgent(ctx.alloc);
        const applies = agent.checkPatch(fdata) catch |err| apl: {
            std.debug.print("git apply failed {any}\n", .{err});
            break :apl "";
        };
        if (applies == null) patch_applies = true;
    } else |err| {
        std.debug.print("Unable to load patch {} {s}\n", .{ err, patch_filename });
    }

    var root_thread: []S.Thread = &[0]S.Thread{};
    if (delta.getMessages(ctx.alloc)) |messages| {
        root_thread = try ctx.alloc.alloc(S.Thread, messages.len);
        for (messages, root_thread) |msg, *c_ctx| {
            switch (msg.kind) {
                .comment => |comment| {
                    c_ctx.* = .{
                        .author = try abx.Html.cleanAlloc(ctx.alloc, comment.author),
                        .date = try allocPrint(ctx.alloc, "{}", .{Humanize.unix(msg.updated)}),
                        .message = if (patch) |pt|
                            translateComment(ctx.alloc, comment.message, pt, &repo) catch unreachable
                        else
                            try abx.Html.cleanAlloc(ctx.alloc, comment.message),
                        .direct_reply = .{ .uri = try allocPrint(ctx.alloc, "{}/direct_reply/{x}", .{
                            index,
                            fmtSliceHexLower(msg.hash[0..]),
                        }) },
                        .sub_thread = null,
                    };
                },
                else => {
                    c_ctx.* = .{
                        .author = "",
                        .date = "",
                        .message = "unsupported message type",
                        .direct_reply = null,
                        .sub_thread = null,
                    };
                },
            }
        }
    } else |err| {
        std.debug.print("Unable to load comments for thread {} {}\n", .{ index, err });
        @panic("oops");
    }

    const username = if (ctx.user) |usr| usr.username.? else "public";

    var page = DiffViewPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = .{ .nav = .{
            .nav_buttons = &try Repos.navButtons(ctx),
        } },
        .patch = if (patch_formatted) |pf| .{
            .header = patch_header,
            .patch = pf,
        } else .{
            .header = patch_header,
            .patch = .{ .files = &[0]Template.Structs.Files{} },
        },
        .comments = .{ .thread = root_thread },
        .delta_id = delta_id,
        .patch_does_not_apply = if (patch_applies) null else .{},
        .current_username = username,
    });

    try ctx.sendPage(&page);
}

const DeltaListPage = Template.PageData("delta-list.html");
fn list(ctx: *Frame) Error!void {
    const rd = RouteData.init(ctx.uri) orelse return error.Unrouteable;

    const last = Delta.last(rd.name) + 1;

    var d_list = std.ArrayList(S.DeltaList).init(ctx.alloc);
    for (0..last) |i| {
        var d = Delta.open(ctx.alloc, rd.name, i) catch continue orelse continue;
        if (!std.mem.eql(u8, d.repo, rd.name) or d.attach != .diff) {
            d.raze(ctx.alloc);
            continue;
        }

        _ = d.loadThread(ctx.alloc) catch unreachable;
        const cmtsmeta = d.countComments();
        try d_list.append(.{
            .index = try allocPrint(ctx.alloc, "0x{x}", .{d.index}),
            .title_uri = try allocPrint(
                ctx.alloc,
                "/repo/{s}/{s}/{x}",
                .{ d.repo, if (d.attach == .issue) "issues" else "diffs", d.index },
            ),
            .title = try verse.abx.Html.cleanAlloc(ctx.alloc, d.title),
            .comments_icon = try allocPrint(
                ctx.alloc,
                "<span><span class=\"icon{s}\">\xee\xa0\x9c</span> {}</span>",
                .{ if (cmtsmeta.new) " new" else "", cmtsmeta.count },
            ),
            .desc = try verse.abx.Html.cleanAlloc(ctx.alloc, d.message),
        });
    }
    var default_search_buf: [0xFF]u8 = undefined;
    const def_search = try bufPrint(&default_search_buf, "is:diffs repo:{s} ", .{rd.name});
    const meta_head = Template.Structs.MetaHeadHtml{
        .open_graph = .{},
    };
    var page = DeltaListPage.init(.{
        .meta_head = meta_head,
        .body_header = .{ .nav = .{
            .nav_buttons = &try Repos.navButtons(ctx),
        } },
        .delta_list = try d_list.toOwnedSlice(),
        .search = def_search,
    });

    return try ctx.sendPage(&page);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const eql = std.mem.eql;
const fmtSliceHexLower = std.fmt.fmtSliceHexLower;
const indexOf = std.mem.indexOf;
const indexOfAny = std.mem.indexOfAny;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const isDigit = std.ascii.isDigit;
const isWhitespace = std.ascii.isWhitespace;
const parseInt = std.fmt.parseInt;
const splitScalar = std.mem.splitScalar;

const Repos = @import("../repos.zig");
const RouteData = Repos.RouteData;

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

const Patch = @import("../../patch.zig");
const Route = verse.Router;
const S = Template.Structs;
const Types = @import("../../types.zig");
const Delta = Types.Delta;
