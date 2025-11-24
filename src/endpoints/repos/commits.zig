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

fn commitHtml(f: *Frame, sha: []const u8, repo_name_: []const u8, repo: Git.Repo) Error!void {
    const now: i64 = (Io.Clock.now(.real, f.io) catch unreachable).toSeconds();
    if (!Git.commitish(sha)) {
        std.debug.print("Abuse ''{s}''\n", .{sha});
        return error.Abuse;
    }

    // lol... I'd forgotten I'd done this. >:)
    const current: Git.Commit = repo.commit(.initPartial(sha), f.alloc, f.io) catch cmt: {
        std.debug.print("unable to find commit, trying expensive fallback\n", .{});
        // TODO return 404
        var fallback: Git.Commit = repo.headCommit(f.alloc, f.io) catch return error.Unknown;
        while (!std.mem.startsWith(u8, fallback.sha.hex()[0..], sha)) {
            fallback = fallback.toParent(0, &repo, f.alloc, f.io) catch return f.sendDefaultErrorPage(.not_found);
        }
        break :cmt fallback;
    };

    var git = repo.getAgent(f.alloc);
    var diff = git.show(current.sha) catch |err| switch (err) {
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
        allocPrint(f.alloc, "{f}", .{abx.Html{ .text = current.author.name }}) catch unreachable,
        diffstat.files,
        if (diffstat.files > 1) "s" else "",
        diffstat.additions,
        diffstat.deletions,
    });
    const meta_head = S.MetaHeadHtml{
        .open_graph = .{
            .title = og_title,
            .desc = allocPrint(f.alloc, "{f}", .{abx.Html{ .text = current.message }}) catch unreachable,
        },
    };

    var thread: []Template.Structs.Thread = &[0]Template.Structs.Thread{};
    if (CommitMap.open(repo_name_, current.sha.hex(), f.alloc, f.io)) |map| {
        switch (map.attach_to) {
            .delta => {
                var delta = Delta.open(repo_name_, map.attach_target, f.alloc, f.io) catch return error.DataInvalid;
                if (delta.loadThread(f.alloc, f.io)) |dthread| {
                    thread = try f.alloc.alloc(Template.Structs.Thread, dthread.messages.items.len);
                    for (dthread.messages.items, thread) |msg, *pg_comment| {
                        switch (msg.kind) {
                            .comment => {
                                pg_comment.* = .{
                                    .author = try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = msg.author.? }}),
                                    .date = try allocPrint(f.alloc, "{f}", .{Humanize.unix(msg.updated, now)}),
                                    .message = try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = msg.message.? }}),
                                    .direct_reply = null,
                                    .sub_thread = null,
                                };
                            },
                            .diff_update => {
                                pg_comment.* = .{
                                    .author = try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = msg.author.? }}),
                                    .date = try allocPrint(f.alloc, "{f}", .{Humanize.unix(msg.updated, now)}),
                                    .message = msg.message.?,
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

    const inline_html: bool = getAndSavePatchView(f);

    const upstream: ?S.Upstream = if (repo.findRemote("upstream")) |up| .{
        .href = try allocPrint(f.alloc, "{f}", .{std.fmt.alt(up, .formatLink)}),
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

        const diff = acts.formatPatchRange(range) catch return error.ServerFault;
        f.status = .ok;
        f.content_type = null;
        f.headers.addCustom(f.alloc, "Content-Type", "text/x-patch") catch unreachable; // Firefox is trash
        try f.sendHeaders(.close);
        try f.downstream.writer.writeAll(diff);
        return;
    }
    return f.sendDefaultErrorPage(.bad_request);
}

pub fn viewCommit(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    if (rd.verb == null) return commitList(f);

    const sha = rd.ref orelse return error.Unrouteable;
    if (std.mem.indexOf(u8, sha, ".") != null and !std.mem.endsWith(u8, sha, ".patch")) return error.Unrouteable;

    var repo = (repos.open(rd.name, .public, f.io) catch return error.ServerFault) orelse
        return f.sendDefaultErrorPage(.not_found);
    repo.loadData(f.alloc, f.io) catch return error.Unknown;
    defer repo.raze(f.alloc, f.io);

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
        Highlight.translate(a, .markdown, c.body) catch allocPrint(a, "{f}", .{Verse.abx.Html{ .text = c.body }}) catch unreachable
    else
        allocPrint(a, "{f}", .{Verse.abx.Html{ .text = c.body }}) catch unreachable;
    const sha = try a.dupe(u8, c.sha.hex()[0..]);
    return .{
        .author = allocPrint(a, "{f}", .{Verse.abx.Html{ .text = c.author.name }}) catch unreachable,
        .parents = try commitCtxParents(a, c, repo),
        .repo = repo,
        .sha = sha,
        .sha_short = sha[0..8],
        .title = allocPrint(a, "{f}", .{Verse.abx.Html{ .text = c.title }}) catch unreachable,
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

    const email = if (!include_email) "" else try allocPrint(a, "{f}", .{abx.Html{ .text = trim(u8, c.author.email, ws) }});

    return .{
        .repo = repo_name,
        .body = if (c.body.len > 0) try allocPrint(a, "{f}", .{abx.Html{ .text = trim(u8, c.body, ws) }}) else null,
        .title = try allocPrint(a, "{f}", .{abx.Html{ .text = trim(u8, c.title, ws) }}),
        .cmt_line_src = .{
            .pre = "by ",
            .link_root = "/user?user=",
            .link_target = email,
            .name = try allocPrint(a, "{f}", .{abx.Html{ .text = trim(u8, c.author.name, ws) }}),
        },
        .day = try allocPrint(a, "{f}", .{std.fmt.alt(date, .format)}),
        .weekday = date.weekdaySlice(),
        .time = try allocPrint(a, "{f}", .{std.fmt.alt(date, .fmtDay)}),
        .sha = try allocPrint(a, "{s}", .{c.sha.hex()[0..8]}),
    };
}

fn buildList(
    list: *ArrayList(S.CommitList),
    repo: *const Git.Repo,
    name: []const u8,
    before: ?Git.SHA,
    include_email: bool,
    a: Allocator,
    io: Io,
) !?Git.SHA {
    return buildListBetween(list, repo, name, null, before, include_email, a, io);
}

fn buildListBetween(
    list: *ArrayList(S.CommitList),
    repo: *const Git.Repo,
    name: []const u8,
    left: ?Git.SHA,
    right: ?Git.SHA,
    include_email: bool,
    a: Allocator,
    io: Io,
) !?Git.SHA {
    var current: Git.Commit = repo.headCommit(a, io) catch return error.Unknown;
    if (right) |r| while (!current.sha.startsWith(r)) {
        current = current.toParent(0, repo, a, io) catch |err| {
            std.debug.print("unable to build commit history {}\n", .{err});
            return err;
        };
    };

    while (!current.sha.startsWith(left orelse .empty)) {
        list.appendBounded(try commitVerse(a, current, name, include_email)) catch return current.sha;
        current = current.toParent(0, repo, a, io) catch |err| switch (err) {
            else => {
                std.debug.print("unable to build commit history {}\n", .{err});
                return err;
            },
            error.NoParent => return null,
        };
    }

    return current.parent[0] orelse return current.sha;
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

    var repo = (repos.open(rd.name, .public, f.io) catch return error.ServerFault) orelse
        return f.sendDefaultErrorPage(.not_found);
    repo.loadData(f.alloc, f.io) catch return error.Unknown;
    defer repo.raze(f.alloc, f.io);

    var l_b: [50]S.CommitList = undefined;
    var list: ArrayList(S.CommitList) = .initBuffer(&l_b);
    const last_sha: ?Git.SHA = buildList(&list, &repo, rd.name, commitish, f.user != null, f.alloc, f.io) catch
        return error.Unknown;

    return sendCommits(f, list.items, rd.name, last_sha);
}

pub fn commitsBefore(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;

    std.debug.assert(std.mem.eql(u8, "after", f.uri.next().?));

    var repo = (repos.open(rd.name, .public) catch return error.ServerFault) orelse
        return f.sendDefaultErrorPage(.not_found);
    repo.loadData(f.alloc) catch return error.Unknown;
    defer repo.raze(f.alloc, f.io);

    const before: Git.SHA = if (f.uri.next()) |bf| Git.SHA.initPartial(bf);
    const commits_b = try f.alloc.alloc(Template.Verse, 50);

    var l_b: [50]S.CommitList = undefined;
    var list: ArrayList(S.CommitList) = .initBuffer(&l_b);
    const last_sha = try buildList(&list, &repo, rd.name, before, commits_b, f.alloc, f.io);
    return sendCommits(f, list.items, rd.name, last_sha);
}

fn sendCommits(f: *Frame, list: []const S.CommitList, repo_name: []const u8, sha: ?Git.SHA) Error!void {
    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };
    const last_sha: ?[]const u8 = if (sha) |s| s.hex()[0..8] else null;
    var page = CommitsListPage.init(.{
        .meta_head = meta_head,
        .body_header = .{ .nav = .{ .nav_buttons = &try Repos.navButtons(f) } },

        .commit_list = list,
        .after_commits = if (last_sha) |s| .{
            .repo_name = repo_name,
            .sha = s,
        } else null,
    });

    try f.sendPage(&page);
}

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
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
const getAndSavePatchView = Repos.getAndSavePatchView;

const Datetime = @import("../../datetime.zig");
const Git = @import("../../git.zig");
const Highlight = @import("../../syntax-highlight.zig");
const Humanize = @import("../../humanize.zig");
const Patch = @import("../../patch.zig");
const repos = @import("../../repos.zig");

const Types = @import("../../types.zig");
const CommitMap = Types.CommitMap;
const Delta = Types.Delta;
