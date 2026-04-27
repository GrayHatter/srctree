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

fn commitHtml(f: *Frame, sha: []const u8, repo_name: []const u8, repo: Git.Repo) Error!void {
    const now: i64 = Io.Clock.real.now(f.io).toSeconds();
    if (!Git.commitish(sha)) {
        std.debug.print("Abuse ''{s}''\n", .{sha});
        return error.Abuse;
    }

    // lol... I'd forgotten I'd done this. >:)
    const current: Git.Commit = repo.commit(.init(sha), f.alloc, f.io) catch |err| cmt: {
        std.debug.print("unable to find commit {}, trying expensive fallback\n", .{err});
        // TODO return 404
        var fallback: Git.Commit = repo.headCommit(f.alloc, f.io) catch return error.Unknown;
        while (!fallback.sha.startsWith(.init(sha))) {
            fallback = fallback.toParent(0, &repo, f.alloc, f.io) catch |err2| {
                log.err("fallback to parent failed {}", .{err2});
                return f.sendDefaultErrorPage(.not_found);
            };
        }
        break :cmt fallback;
    };

    var git = repo.getAgent(f.alloc);
    var diff = git.show(current.sha, f.io) catch |err| switch (err) {
        //error.StdoutStreamTooLong => return f.sendDefaultErrorPage(.internal_server_error),
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

    var messages: []S.CommentThreadHtml.Messages = &.{};
    if (CommitMap.open(repo_name, current.sha, f.alloc, f.io)) |map| {
        switch (map.attach_to) {
            .delta => {
                var delta = Delta.open(repo_name, map.attach_target, f.alloc, f.io) catch return error.DataInvalid;
                messages = try delta_shared.genThreadMessages(
                    &delta,
                    &repo,
                    &patch,
                    .{ .edit = f.user != null },
                    f.alloc,
                    f.io,
                );
            },
            else => {},
        }
    } else |_| {}

    const patch_view_mode = updateFetchPatchView(f) catch .inlined;

    const upstream: ?S.BaseRepoHeaderHtml.Upstream = if (repo.findRemote("upstream")) |up| .{
        .href = .safe(try allocPrint(f.alloc, "{f}", .{std.fmt.alt(up, .formatLink)})),
    } else null;

    const human_time = Humanize.unix(current.committer.timestamp, now);

    const page_title = try allocPrint(f.alloc, "{f} - [{s}] committed to {s} about {f} - srctree", .{
        abx.Html{ .text = current.title },
        current.sha.text().slice()[0..10],
        repo_name,
        human_time,
    });

    const og_title = try allocPrint(f.alloc, "Commit by {s}: changed {} file{s} {f} [+{} -{}k", .{
        allocPrint(f.alloc, "{f}", .{abx.Html{ .text = current.author.name }}) catch unreachable,
        diffstat.files,
        if (diffstat.files > 1) "s" else "",
        human_time,
        diffstat.additions,
        diffstat.deletions,
    });
    const og_desc = allocPrint(f.alloc, "{f}", .{abx.Html{ .text = current.message }}) catch unreachable;
    var page = CommitPage.init(.{
        .meta_head = .{ .title = page_title, .open_graph = .{ .title = og_title, .desc = og_desc } },
        .body_header = .{ .nav = .{ .nav_buttons = &try Repos.navButtons(f) } },
        .repo_header = .{
            .repo_name = .abx(repo_name),
            .description = .abx(repo.description(f.alloc, f.io) catch ""),
            .git_uri = .{ .host = .safe("srctree.gr.ht"), .repo_name = .abx(repo_name) },
            .upstream = upstream,
            .blame = null,
        },
        .commit = try commitCtx(current, repo_name, f.alloc, f.io),
        .comments = .{ .messages = messages },
        .patch = Diffs.patchStruct(f.alloc, &patch, patch_view_mode) catch return error.Unknown,
        .inline_toggle = if (patch_view_mode == .inlined) .inlined else .split,
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

        const diff = acts.formatPatchRange(range, f.io) catch return error.ServerFault;
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

    const vis: repos.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo = (repos.open(rd.name, vis, f.io) catch return error.ServerFault) orelse {
        log.err("Repo doesn't exist? {s}", .{rd.name});
        return f.sendDefaultErrorPage(.not_found);
    };
    repo.loadData(f.alloc, f.io) catch return error.Unknown;
    defer repo.raze(f.alloc, f.io);

    if (endsWith(u8, sha, ".patch")) {
        return viewAsPatch(f, sha, repo);
    } else {
        return commitHtml(f, sha, rd.name, repo);
    }
}

pub fn commitCtxParents(c: Git.Commit, repo: []const u8, a: Allocator) ![]S.CommitHtml.Commit.Parents {
    var plen: usize = 0;
    for (c.parent) |cp| {
        if (cp != null) plen += 1;
    }
    const parents = try a.alloc(S.CommitHtml.Commit.Parents, plen);
    errdefer a.free(parents);
    for (parents, c.parent[0..plen]) |*par, par_cmt| {
        // TODO leaks on err
        if (par_cmt == null) continue;
        par.* = .{
            .repo = .abx(repo),
            .parent_sha_short = .safe(try par_cmt.?.text().dupe(a)),
        };
    }

    return parents;
}

pub fn commitCtx(c: Git.Commit, repo: []const u8, a: Allocator, io: Io) !S.CommitHtml.Commit {
    //const clean_body = Verse.abx.Html.cleanAlloc(a, c.body) catch unreachable;
    var r: Reader = .fixed(c.body);
    var w: Writer.Allocating = try .initCapacity(a, c.body.len);
    Highlight.Markdown.translate(&r, &w.writer, a, io) catch |err| switch (err) {
        error.InvalidMarkdown => w.writer.print("{f}", .{Verse.abx.Html{ .text = c.body }}) catch unreachable,
        error.OutOfMemory, error.WriteFailed => return error.ServerFault,
    };
    const sha = try a.dupe(u8, c.sha.text().slice());
    return .{
        .author = .abx(c.author.name),
        .parents = try commitCtxParents(c, repo, a),
        .repo = .abx(repo),
        .sha = .safe(sha),
        .sha_short = .safe(sha[0..8]),
        .title = .abx(c.title),
        .body = w.written(),
    };
}

fn commitVerse(a: Allocator, c: Git.Commit, repo_name: []const u8, include_email: bool) !S.CommitListHtml.CommitList {
    var parcount: usize = 0;
    for (c.parent) |p| {
        if (p != null) parcount += 1;
    }
    var par_ptr: [*]const ?Git.Sha = &c.parent;
    for (0..parcount) |i| {
        var lim = 9 - i;
        while (lim > 0 and par_ptr[i] == null) {
            par_ptr += 1;
            lim -= 1;
        }
    }
    const ws = " \t\n";
    const date = Datetime.fromEpoch(c.author.timestamp);

    const email = if (!include_email) "" else try allocPrint(a, "{f}", .{
        abx.Html{ .text = trim(u8, c.author.email, ws) },
    });

    return .{
        .repo = .abx(repo_name),
        .body = if (c.body.len > 0) try allocPrint(a, "{f}", .{abx.Html{ .text = trim(u8, c.body, ws) }}) else null,
        .title = .abx(trim(u8, c.title, ws)),
        .cmt_line_src = .{
            .pre = .safe("by "),
            .link_root = .safe("/user?user="),
            .link_target = .abx(email),
            .name = .abx(trim(u8, c.author.name, ws)),
        },
        .day = .safe(try allocPrint(a, "{f}", .{std.fmt.alt(date, .format)})),
        .weekday = .safe(date.weekdaySlice()),
        .time = .safe(try allocPrint(a, "{f}", .{std.fmt.alt(date, .fmtDay)})),
        .sha = .safe(try allocPrint(a, "{f}", .{std.fmt.alt(c.sha, .fmtHex)})),
    };
}

fn buildList(
    list: *ArrayList(S.CommitListHtml.CommitList),
    repo: *const Git.Repo,
    name: []const u8,
    before: ?Git.Sha,
    include_email: bool,
    a: Allocator,
    io: Io,
) !?Git.Sha {
    return buildListBetween(list, repo, name, null, before, include_email, a, io);
}

fn buildListBetween(
    list: *ArrayList(S.CommitListHtml.CommitList),
    repo: *const Git.Repo,
    name: []const u8,
    left: ?Git.Sha,
    right: ?Git.Sha,
    include_email: bool,
    a: Allocator,
    io: Io,
) !?Git.Sha {
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

    var commitish: ?Git.Sha = null;
    if (f.uri.next()) |next| if (eql(u8, next, "before")) {
        if (f.uri.next()) |before| commitish = .init(before);
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

    const vis: repos.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo = (repos.open(rd.name, vis, f.io) catch return error.ServerFault) orelse
        return f.sendDefaultErrorPage(.not_found);
    repo.loadData(f.alloc, f.io) catch return error.Unknown;
    defer repo.raze(f.alloc, f.io);

    var l_b: [50]S.CommitListHtml.CommitList = undefined;
    var list: ArrayList(S.CommitListHtml.CommitList) = .initBuffer(&l_b);
    const last_sha: ?Git.Sha = buildList(&list, &repo, rd.name, commitish, f.user != null, f.alloc, f.io) catch
        return error.Unknown;

    return sendCommits(f, list.items, rd.name, last_sha);
}

pub fn commitsBefore(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;

    std.debug.assert(std.mem.eql(u8, "after", f.uri.next().?));

    const vis: repos.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo = (repos.open(rd.name, vis, f.io) catch return error.ServerFault) orelse
        return f.sendDefaultErrorPage(.not_found);
    repo.loadData(f.alloc) catch return error.Unknown;
    defer repo.raze(f.alloc, f.io);

    const before: Git.Sha = if (f.uri.next()) |bf| .init(bf);
    const commits_b = try f.alloc.alloc(Template.Verse, 50);

    var l_b: [50]S.CommitListHtml.CommitList = undefined;
    var list: ArrayList(S.CommitListHtml.CommitList) = .initBuffer(&l_b);
    const last_sha = try buildList(&list, &repo, rd.name, before, commits_b, f.alloc, f.io);
    return sendCommits(f, list.items, rd.name, last_sha);
}

fn sendCommits(f: *Frame, list: []const S.CommitListHtml.CommitList, repo_name: []const u8, sha: ?Git.Sha) Error!void {
    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };
    const sha_text = if (sha) |s| s.text() else Git.Sha.Text.zeros;
    var page = CommitsListPage.init(.{
        .meta_head = meta_head,
        .body_header = .{ .nav = .{ .nav_buttons = &try Repos.navButtons(f) } },

        .commit_list = list,
        .after_commits = if (sha) |_| .{
            .repo_name = .abx(repo_name),
            .sha = .safe(sha_text.slice()),
        } else null,
    });

    try f.sendPage(&page);
}

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
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
const updateFetchPatchView = Repos.updateFetchPatchView;

const Datetime = @import("../../datetime.zig");
const Git = @import("../../git.zig");
const Highlight = @import("../../syntax-highlight.zig");
const Humanize = @import("../../humanize.zig");
const Patch = @import("../../patch.zig");
const repos = @import("../../repos.zig");
const delta_shared = @import("../delta.zig");

const Types = @import("../../types.zig");
const CommitMap = Types.CommitMap;
const Delta = Types.Delta;
const log = std.log.scoped(.srctree_commits);
