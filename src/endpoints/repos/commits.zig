pub const routes = [_]Router.MatchRouter{
    Router.ROUTE("", commitList),
    Router.GET("before", commitsBefore),
};

const CommitPage = Template.PageData("commit.html");
const CommitsListPage = Template.PageData("commit-list.html");

const AddComment = struct {
    text: []const u8,
};

pub fn router(f: *Frame) Router.RoutingError!Router.BuildFn {
    const rd = RouteData.init(f.uri) orelse return commitList;
    if (rd.verb != null and rd.verb.? == .commit)
        return viewCommit;
    return commitList;
}

fn newComment(f: *Frame) Error!void {
    if (f.request.data.post) |post| {
        _ = post.validate(AddComment) catch return error.DataInvalid;
    }
    return error.DataInvalid;
}

pub fn patchVerse(a: Allocator, patch: *Patch.Patch) ![]Template.Context {
    patch.parse(a) catch |err| {
        if (std.mem.indexOf(u8, patch.blob, "\nMerge: ") == null) {
            std.debug.print("'''\n{s}\n'''\n", .{patch.blob});
        } else {
            std.debug.print("Unable to parse diff {} (merge commit)\n", .{err});
        }

        return error.PatchInvalid;
    };

    return try patch.diffsVerseSlice(a);
}

pub const PatchView = struct {
    @"inline": ?bool = null,
};

fn commitHtml(f: *Frame, sha: []const u8, repo_name_: []const u8, repo: Git.Repo) Error!void {
    if (!Git.commitish(sha)) {
        std.debug.print("Abuse ''{s}''\n", .{sha});
        return error.Abuse;
    }

    // lol... I'd forgotten I'd done this. >:)
    const current: Git.Commit = repo.commit(f.alloc, Git.SHA.initPartial(sha)) catch cmt: {
        std.debug.print("unable to find commit, trying expensive fallback\n", .{});
        // TODO return 404
        var fallback: Git.Commit = repo.headCommit(f.alloc) catch return error.Unknown;
        while (!std.mem.startsWith(u8, fallback.sha.hex()[0..], sha)) {
            fallback = fallback.toParent(f.alloc, 0, &repo) catch return f.sendDefaultErrorPage(.not_found);
        }
        break :cmt fallback;
    };

    var git = repo.getAgent(f.alloc);
    var diff = git.show(sha) catch |err| switch (err) {
        error.StdoutStreamTooLong => return f.sendDefaultErrorPage(.internal_server_error),
        else => return error.Unknown,
    };

    if (std.mem.indexOf(u8, diff, "diff")) |i| {
        diff = diff[i..];
    }
    var patch: Patch = .init(diff);

    //for ([_]Comment{ .{
    //    .author = "robinli",
    //    .message = "Woah, I didn't know srctree had the ability to comment on commits!",
    //}, .{
    //    .author = "grayhatter",
    //    .message = "Hah, yeah, added it the other day... pretty dope huh?",
    //} }) |cm| {
    //    comments.pushSlice(addComment(f.alloc, cm) catch unreachable);
    //}

    const diffstat = patch.patchStat();
    const og_title = try allocPrint(f.alloc, "Commit by {s}: {} file{s} changed +{} -{}", .{
        Verse.abx.Html.cleanAlloc(f.alloc, current.author.name) catch unreachable,
        diffstat.files,
        if (diffstat.files > 1) "s" else "",
        diffstat.additions,
        diffstat.deletions,
    });
    const meta_head = S.MetaHeadHtml{
        .open_graph = .{
            .title = og_title,
            .desc = Verse.abx.Html.cleanAlloc(f.alloc, current.message) catch unreachable,
        },
    };

    var thread: []Template.Structs.Thread = &[0]Template.Structs.Thread{};
    if (CommitMap.open(f.alloc, repo_name_, current.sha.hex())) |map| {
        switch (map.attach_to) {
            .delta => {
                var delta = Delta.open(f.alloc, repo_name_, map.attach_target) catch return error.DataInvalid;
                if (delta.loadThread(f.alloc)) |dthread| {
                    thread = try f.alloc.alloc(Template.Structs.Thread, dthread.messages.len);
                    for (dthread.messages, thread) |msg, *pg_comment| {
                        switch (msg.kind) {
                            .comment => {
                                pg_comment.* = .{
                                    .author = try Verse.abx.Html.cleanAlloc(f.alloc, msg.author.?),
                                    .date = try allocPrint(f.alloc, "{}", .{Humanize.unix(msg.updated)}),
                                    .message = try Verse.abx.Html.cleanAlloc(f.alloc, msg.message.?),
                                    .direct_reply = null,
                                    .sub_thread = null,
                                };
                            },
                            //else => {
                            //    pg_comment.* = .{
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
                    std.debug.print(
                        "Unable to load comments for thread {} {}\n",
                        .{ map.attach_target, err },
                    );
                    @panic("oops");
                }
            },
            else => {},
        }
    } else |_| {}

    var inline_html: bool = true;
    const udata = f.request.data.query.validate(PatchView) catch return error.DataInvalid;
    if (udata.@"inline") |uinline| {
        inline_html = uinline;
        f.cookie_jar.add(.{
            .name = "diff-inline",
            .value = if (uinline) "1" else "0",
        }) catch @panic("OOM");
    } else {
        if (f.request.cookie_jar.get("diff-inline")) |cookie| {
            inline_html = if (cookie.value.len > 0 and cookie.value[0] == '1') true else false;
        }
    }

    const upstream: ?S.Upstream = if (repo.findRemote("upstream") catch null) |up| .{
        .href = try allocPrint(f.alloc, "{link}", .{up}),
    } else null;

    const repo_name = try f.alloc.dupe(u8, repo_name_);
    var page = CommitPage.init(.{
        .meta_head = meta_head,
        .body_header = .{ .nav = .{ .nav_buttons = &try Repos.navButtons(f) } },
        .tree_blob_header = .{
            .git_uri = .{
                .host = "srctree.gr.ht",
                .repo_name = repo_name_,
            },
            .repo_name = repo_name_,
            .upstream = upstream,
            .blame = null,
        },
        .commit = try commitCtx(f.alloc, current, repo_name),
        .comments = .{ .thread = thread },
        .patch = Diffs.patchStruct(f.alloc, &patch, !inline_html) catch return error.Unknown,
        .inline_toggle = if (inline_html) .inlined else .split,
    });

    f.status = .ok;
    return f.sendPage(&page) catch unreachable;
}

pub fn viewAsPatch(f: *Frame, sha: []const u8, repo: Git.Repo) Error!void {
    var acts = repo.getAgent(f.alloc);
    if (endsWith(u8, sha, ".patch")) {
        var rbuf: [0xff]u8 = undefined;
        const commit_only = sha[0 .. sha.len - 6];
        const range = try bufPrint(rbuf[0..], "{s}^..{s}", .{ commit_only, commit_only });

        const diff = acts.formatPatch(range) catch return error.ServerFault;
        f.status = .ok;
        f.content_type = null;
        f.headers.addCustom(f.alloc, "Content-Type", "text/x-patch") catch unreachable; // Firefox is trash
        f.sendHeaders() catch return error.ServerFault;
        try f.sendRawSlice("\r\n");
        try f.sendRawSlice(diff);
        return;
    }
    return f.sendDefaultErrorPage(.bad_request);
}

pub fn viewCommit(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    if (rd.verb == null) return commitList(f);

    const sha = rd.ref orelse return error.Unrouteable;
    if (std.mem.indexOf(u8, sha, ".") != null and !std.mem.endsWith(u8, sha, ".patch")) return error.Unrouteable;

    var repo = (repos.open(rd.name, .public) catch return error.ServerFault) orelse
        return f.sendDefaultErrorPage(.not_found);
    repo.loadData(f.alloc) catch return error.Unknown;
    defer repo.raze();

    if (std.mem.endsWith(u8, sha, ".patch")) {
        return viewAsPatch(f, sha, repo);
    } else {
        return commitHtml(f, sha, rd.name, repo);
    }
}

pub fn commitCtxParents(a: Allocator, c: Git.Commit, repo: []const u8) ![]S.Parents {
    var plen: usize = 0;
    for (c.parent) |cp| {
        if (cp != null) plen += 1;
    }
    const parents = try a.alloc(Template.Structs.Parents, plen);
    errdefer a.free(parents);
    for (parents, c.parent[0..plen]) |*par, par_cmt| {
        // TODO leaks on err
        if (par_cmt == null) continue;
        par.* = .{
            .repo = repo,
            .parent_sha_short = try a.dupe(u8, par_cmt.?.hex()[0..8]),
        };
    }

    return parents;
}

pub fn commitCtx(a: Allocator, c: Git.Commit, repo: []const u8) !S.Commit {
    //const clean_body = Verse.abx.Html.cleanAlloc(a, c.body) catch unreachable;
    const body = if (c.body.len > 3)
        Highlight.translate(a, .markdown, c.body) catch Verse.abx.Html.cleanAlloc(a, c.body) catch unreachable
    else
        Verse.abx.Html.cleanAlloc(a, c.body) catch unreachable;
    const sha = try a.dupe(u8, c.sha.hex()[0..]);
    return .{
        .author = Verse.abx.Html.cleanAlloc(a, c.author.name) catch unreachable,
        .parents = try commitCtxParents(a, c, repo),
        .repo = repo,
        .sha = sha,
        .sha_short = sha[0..8],
        .title = Verse.abx.Html.cleanAlloc(a, c.title) catch unreachable,
        .body = body,
    };
}

fn commitVerse(a: Allocator, c: Git.Commit, repo_name: []const u8, include_email: bool) !S.CommitList {
    var parcount: usize = 0;
    for (c.parent) |p| {
        if (p != null) parcount += 1;
    }
    var par_ptr: [*]const ?Git.SHA = &c.parent;
    for (0..parcount) |i| {
        var lim = 9 - i;
        while (lim > 0 and par_ptr[i] == null) {
            par_ptr += 1;
            lim -= 1;
        }
    }
    const ws = " \t\n";
    const date = Datetime.fromEpoch(c.author.timestamp);

    const email = if (!include_email) "" else try abx.Html.cleanAlloc(a, trim(u8, c.author.email, ws));

    return .{
        .repo = repo_name,
        .body = if (c.body.len > 0) try abx.Html.cleanAlloc(a, trim(u8, c.body, ws)) else null,
        .title = try abx.Html.cleanAlloc(a, trim(u8, c.title, ws)),
        .cmt_line_src = .{
            .pre = "by ",
            .link_root = "/user?user=",
            .link_target = email,
            .name = try abx.Html.cleanAlloc(a, trim(u8, c.author.name, ws)),
        },
        .day = try allocPrint(a, "{Y-m-d}", .{date}),
        .weekday = date.weekdaySlice(),
        .time = try allocPrint(a, "{time}", .{date}),
        .sha = try allocPrint(a, "{s}", .{c.sha.hex()[0..8]}),
    };
}

fn buildList(
    a: Allocator,
    repo: Git.Repo,
    name: []const u8,
    before: ?Git.SHA,
    count: usize,
    outsha: *Git.SHA,
    include_email: bool,
) ![]S.CommitList {
    return buildListBetween(a, repo, name, null, before, count, outsha, include_email);
}

fn buildListBetween(
    a: Allocator,
    repo: Git.Repo,
    name: []const u8,
    left: ?Git.SHA,
    right: ?Git.SHA,
    count: usize,
    outsha: *Git.SHA,
    include_email: bool,
) ![]S.CommitList {
    var commits = try a.alloc(S.CommitList, count);
    var current: Git.Commit = repo.headCommit(a) catch return error.Unknown;
    if (right) |r| {
        while (!current.sha.eqlIsh(r)) {
            current = current.toParent(a, 0, &repo) catch |err| {
                std.debug.print("unable to build commit history\n", .{});
                return err;
            };
        }
        current = current.toParent(a, 0, &repo) catch |err| {
            std.debug.print("unable to build commit history\n", .{});
            return err;
        };
    }
    var found: usize = 0;
    for (commits, 1..) |*c, i| {
        c.* = try commitVerse(a, current, name, include_email);
        found = i;
        outsha.* = current.sha;
        if (left) |l| if (current.sha.eqlIsh(l)) break;
        current = current.toParent(a, 0, &repo) catch break;
    }
    if (a.resize(commits, found)) {
        commits.len = found;
    } else unreachable; // lol, good luck!
    return commits;
}

pub fn commitList(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;

    if (f.uri.next()) |next| {
        if (!std.mem.eql(u8, next, "commits")) return error.Unrouteable;
    }

    var commitish: ?Git.SHA = null;
    if (f.uri.next()) |next| if (eql(u8, next, "before")) {
        if (f.uri.next()) |before| commitish = Git.SHA.initPartial(before);
    };

    // TODO use left and right commit finding
    //if (commitish) |cmish| {
    //    std.debug.print("{s}\n", .{cmish});
    //    if (!Git.commitish(cmish)) return error.Unrouteable;
    //    if (std.mem.indexOf(u8, cmish, "..")) |i| {
    //        const left = cmish[0..i];
    //        if (!Git.commitish(left)) return error.Unrouteable;
    //        const right = cmish[i + 2 ..];
    //        if (!Git.commitish(right)) return error.Unrouteable;
    //        std.debug.print("{s}, {s}\n", .{ left, right });
    //    }
    //} else {}

    var repo = (repos.open(rd.name, .public) catch return error.ServerFault) orelse
        return f.sendDefaultErrorPage(.not_found);
    repo.loadData(f.alloc) catch return error.Unknown;
    defer repo.raze();

    var last_sha: Git.SHA = undefined;
    const cmts_list = buildList(
        f.alloc,
        repo,
        rd.name,
        commitish,
        50,
        &last_sha,
        f.user != null,
    ) catch
        return error.Unknown;

    return sendCommits(f, cmts_list, rd.name, last_sha.hex()[0..8]);
}

pub fn commitsBefore(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;

    std.debug.assert(std.mem.eql(u8, "after", f.uri.next().?));

    var repo = (repos.open(rd.name, .public) catch return error.ServerFault) orelse
        return f.sendDefaultErrorPage(.not_found);
    repo.loadData(f.alloc) catch return error.Unknown;
    defer repo.raze();

    const before: Git.SHA = if (f.uri.next()) |bf| Git.SHA.initPartial(bf);
    const commits_b = try f.alloc.alloc(Template.Verse, 50);
    var last_sha: Git.SHA = undefined;
    const cmts_list = try buildList(f.alloc, repo, rd.name, before, commits_b, &last_sha);
    return sendCommits(f, cmts_list, rd.name, last_sha[0..]);
}

fn sendCommits(f: *Frame, list: []const S.CommitList, repo_name: []const u8, sha: []const u8) Error!void {
    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };

    var page = CommitsListPage.init(.{
        .meta_head = meta_head,
        .body_header = .{ .nav = .{
            .nav_buttons = &try Repos.navButtons(f),
        } },

        .commit_list = list,
        .after_commits = .{
            .repo_name = repo_name,
            .sha = sha,
        },
    });

    try f.sendPage(&page);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const endsWith = std.mem.endsWith;
const eql = std.mem.eql;
const trim = std.mem.trim;

const Verse = @import("verse");
const Router = Verse.Router;
const Template = Verse.template;
const S = Template.Structs;
const HTML = Verse.HTML;
const Error = Router.Error;
const DOM = Verse.DOM;
const Frame = Verse.Frame;
const abx = Verse.abx;

const Diffs = @import("diffs.zig");

const Repos = @import("../repos.zig");
const RouteData = Repos.RouteData;

const Datetime = @import("../../datetime.zig");
const Git = @import("../../git.zig");
const Highlight = @import("../../syntax-highlight.zig");
const Humanize = @import("../../humanize.zig");
const Patch = @import("../../patch.zig");
const repos = @import("../../repos.zig");

const Types = @import("../../types.zig");
const CommitMap = Types.CommitMap;
const Delta = Types.Delta;
