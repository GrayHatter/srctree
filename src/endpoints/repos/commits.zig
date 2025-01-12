const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const endsWith = std.mem.endsWith;
const eql = std.mem.eql;

const Verse = @import("verse");
const DOM = Verse.DOM;
const HTML = Verse.HTML;
const Route = Verse.Router;
const Template = Verse.template;
const RequestData = Verse.RequestData;

const Diffs = @import("diffs.zig");

const Repos = @import("../repos.zig");

const Git = @import("../../git.zig");
const Bleach = @import("../../bleach.zig");
const Humanize = @import("../../humanize.zig");
const Patch = @import("../../patch.zig");
const Types = @import("../../types.zig");

const S = Template.Structs;
const CommitMap = Types.CommitMap;
const Delta = Types.Delta;
const Error = Route.Error;
const GET = Route.GET;
const ROUTE = Route.ROUTE;
const RouteData = Repos.RouteData;
const Thread = Types.Thread;
const UriIter = Route.UriIter;

pub const routes = [_]Route.MatchRouter{
    ROUTE("", commitsView),
    GET("before", commitsBefore),
};

const CommitPage = Template.PageData("commit.html");
const CommitsListPage = Template.PageData("commit-list.html");

const AddComment = struct {
    text: []const u8,
};

pub fn router(ctx: *Verse.Frame) Route.RoutingError!Route.BuildFn {
    const rd = RouteData.make(&ctx.uri) orelse return commitsView;
    if (rd.verb != null and std.mem.eql(u8, "commit", rd.verb.?))
        return viewCommit;
    return commitsView;
}

fn newComment(ctx: *Verse.Frame) Error!void {
    if (ctx.request.data.post) |post| {
        _ = post.validate(AddComment) catch return error.BadData;
    }
    return error.BadData;
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

fn commitHtml(ctx: *Verse.Frame, sha: []const u8, repo_name: []const u8, repo: Git.Repo) Error!void {
    if (!Git.commitish(sha)) {
        std.debug.print("Abusive ''{s}''\n", .{sha});
        return error.Abusive;
    }

    // lol... I'd forgotten I'd done this. >:)
    const current: Git.Commit = repo.commit(ctx.alloc, Git.SHA.initPartial(sha)) catch cmt: {
        // TODO return 404
        var fallback: Git.Commit = repo.headCommit(ctx.alloc) catch return error.Unknown;
        while (!std.mem.startsWith(u8, fallback.sha.hex[0..], sha)) {
            fallback = fallback.toParent(ctx.alloc, 0, &repo) catch return error.Unknown;
        }
        break :cmt fallback;
    };

    var git = repo.getAgent(ctx.alloc);
    var diff = git.show(sha) catch |err| switch (err) {
        error.StdoutStreamTooLong => return ctx.sendError(.internal_server_error),
        else => return error.Unknown,
    };

    if (std.mem.indexOf(u8, diff, "diff")) |i| {
        diff = diff[i..];
    }
    var patch = Patch.Patch.init(diff);

    //for ([_]Comment{ .{
    //    .author = "robinli",
    //    .message = "Woah, I didn't know srctree had the ability to comment on commits!",
    //}, .{
    //    .author = "grayhatter",
    //    .message = "Hah, yeah, added it the other day... pretty dope huh?",
    //} }) |cm| {
    //    comments.pushSlice(addComment(ctx.alloc, cm) catch unreachable);
    //}

    const diffstat = patch.patchStat();
    const og_title = try allocPrint(ctx.alloc, "Commit by {s}: {} file{s} changed +{} -{}", .{
        Bleach.Html.sanitizeAlloc(ctx.alloc, current.author.name) catch unreachable,
        diffstat.files,
        if (diffstat.files > 1) "s" else "",
        diffstat.additions,
        diffstat.deletions,
    });
    const meta_head = S.MetaHeadHtml{
        .open_graph = .{
            .title = og_title,
            .desc = Bleach.Html.sanitizeAlloc(ctx.alloc, current.message) catch unreachable,
        },
    };

    var thread: []Template.Structs.Thread = &[0]Template.Structs.Thread{};
    if (CommitMap.open(ctx.alloc, repo_name, sha) catch null) |map| {
        var dlt = map.delta(ctx.alloc) catch |err| n: {
            std.debug.print("error generating delta {}\n", .{err});
            break :n @as(?Delta, null);
        };
        if (dlt) |*delta| {
            _ = delta.loadThread(ctx.alloc) catch unreachable;
            if (delta.getMessages(ctx.alloc)) |messages| {
                thread = try ctx.alloc.alloc(Template.Structs.Thread, messages.len);
                for (messages, thread) |msg, *pg_comment| {
                    switch (msg.kind) {
                        .comment => |cmt| {
                            pg_comment.* = .{
                                .author = try Bleach.Html.sanitizeAlloc(ctx.alloc, cmt.author),
                                .date = try allocPrint(ctx.alloc, "{}", .{Humanize.unix(msg.updated)}),
                                .message = try Bleach.Html.sanitizeAlloc(ctx.alloc, cmt.message),
                                .direct_reply = null,
                                .sub_thread = null,
                            };
                        },
                        else => {
                            pg_comment.* = .{
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
                std.debug.print("Unable to load comments for thread {} {}\n", .{ map.attach.delta, err });
                @panic("oops");
            }
        }
    }

    const udata = ctx.request.data.query.validate(Diffs.PatchView) catch return error.BadData;
    const inline_html = udata.@"inline" orelse true;

    var page = CommitPage.init(.{
        .meta_head = meta_head,
        .body_header = .{ .nav = .{
            .nav_buttons = &try Repos.navButtons(ctx),
        } },
        .commit = try commitCtx(ctx.alloc, current, repo_name),
        .comments = .{ .thread = thread },
        .patch = Diffs.patchStruct(ctx.alloc, &patch, !inline_html) catch return error.Unknown,
    });

    ctx.status = .ok;
    return ctx.sendPage(&page) catch unreachable;
}

pub fn commitPatch(ctx: *Verse.Frame, sha: []const u8, repo: Git.Repo) Error!void {
    var acts = repo.getAgent(ctx.alloc);
    if (endsWith(u8, sha, ".patch")) {
        var rbuf: [0xff]u8 = undefined;
        const commit_only = sha[0 .. sha.len - 6];
        const range = try bufPrint(rbuf[0..], "{s}^..{s}", .{ commit_only, commit_only });

        const diff = acts.formatPatch(range) catch return error.Unknown;
        //if (std.mem.indexOf(u8, diff, "diff")) |i| {
        //    diff = diff[i..];
        //}
        ctx.status = .ok;
        ctx.headersAdd("Content-Type", "text/x-patch") catch unreachable; // Firefox is trash
        ctx.sendHeaders() catch return Error.Unknown;
        ctx.sendRawSlice(diff) catch return Error.Unknown;
    }
}

pub fn viewCommit(ctx: *Verse.Frame) Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    if (rd.verb == null) return commitsView(ctx);

    const sha = rd.noun orelse return error.Unrouteable;
    if (std.mem.indexOf(u8, sha, ".") != null and !std.mem.endsWith(u8, sha, ".patch")) return error.Unrouteable;
    const cwd = std.fs.cwd();
    // FIXME user data flows into system
    const filename = try std.fmt.allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    const dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = Git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;
    defer repo.raze();

    if (std.mem.endsWith(u8, sha, ".patch"))
        return commitPatch(ctx, sha, repo)
    else
        return commitHtml(ctx, sha, rd.name, repo);
    return error.Unrouteable;
}

pub fn commitCtxParents(a: Allocator, c: Git.Commit, repo: []const u8) ![]Template.Structs.Parents {
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
            .parent_uri = try allocPrint(a, "/repo/{s}/commit/{s}", .{ repo, par_cmt.?.hex[0..8] }),
            .parent_sha_short = try a.dupe(u8, par_cmt.?.hex[0..8]),
        };
    }

    return parents;
}

pub fn commitCtx(a: Allocator, c: Git.Commit, repo: []const u8) !Template.Structs.Commit {
    return .{
        .author = Bleach.Html.sanitizeAlloc(a, c.author.name) catch unreachable,
        .parents = try commitCtxParents(a, c, repo),
        .sha_uri = try allocPrint(a, "/repo/{s}/commit/{s}", .{ repo, c.sha.hex[0..8] }),
        .sha_short = try a.dupe(u8, c.sha.hex[0..8]),
        //.sha = try a.dupe(u8, c.sha),
        .title = Bleach.Html.sanitizeAlloc(a, c.title) catch unreachable,
        .body = Bleach.Html.sanitizeAlloc(a, c.body) catch unreachable,
    };
}

pub fn htmlCommit(a: Allocator, c: Git.Commit, repo: []const u8, comptime top: bool) ![]HTML.E {
    var dom = DOM.new(a);
    dom = dom.open(HTML.element("commit", null, null));

    var cd_dom = DOM.new(a);
    cd_dom = cd_dom.open(HTML.element("data", null, null));
    cd_dom.push(try HTML.aHrefAlloc(
        a,
        c.sha[0..8],
        try std.fmt.allocPrint(a, "/repo/{s}/commit/{s}", .{ repo, c.sha[0..8] }),
    ));
    cd_dom.push(HTML.br());
    cd_dom.push(HTML.text(Bleach.Html.sanitizeAlloc(a, c.title) catch unreachable));
    if (c.body.len > 0) {
        cd_dom.push(HTML.br());
        cd_dom.push(HTML.text(Bleach.Html.sanitizeAlloc(a, c.body) catch unreachable));
    }
    cd_dom = cd_dom.close();
    const cdata = cd_dom.done();

    if (!top) dom.pushSlice(cdata);

    dom = dom.open(HTML.element(if (top) "top" else "foot", null, null));
    {
        const prnt = c.parent[0] orelse "00000000";
        dom.push(HTML.element("author", try a.dupe(u8, c.author.name), null));
        dom = dom.open(HTML.span(null, null));
        dom.push(HTML.text("parent "));
        dom.push(try HTML.aHrefAlloc(
            a,
            prnt[0..8],
            try std.fmt.allocPrint(a, "/repo/{s}/commit/{s}", .{ repo, prnt[0..8] }),
        ));
        dom = dom.close();
    }
    dom = dom.close();

    if (top) dom.pushSlice(cdata);

    dom = dom.close();
    return dom.done();
}

fn commitVerse(a: Allocator, c: Git.Commit, repo_name: []const u8) !S.Commits {
    var parcount: usize = 0;
    for (c.parent) |p| {
        if (p != null) parcount += 1;
    }
    const parents = try a.alloc(S.CommitParent, parcount);
    errdefer a.free(parents);
    var par_ptr: [*]const ?Git.SHA = &c.parent;
    for (0..parcount) |i| {
        var lim = 9 - i;
        while (lim > 0 and par_ptr[i] == null) {
            par_ptr += 1;
            lim -= 1;
        }
        parents[i] = .{
            .uri = try allocPrint(a, "/repo/{s}/commit/{s}", .{ repo_name, par_ptr[i].?.hex[0..8] }),
            .sha = try allocPrint(a, "{s}", .{par_ptr[i].?.hex[0..8]}),
        };
    }
    return .{
        .sha = try allocPrint(a, "{s}", .{c.sha.hex[0..8]}),
        .uri = try allocPrint(a, "/repo/{s}/commit/{s}", .{ repo_name, c.sha.hex[0..8] }),
        .msg_title = try Bleach.Html.sanitizeAlloc(a, c.title),
        .msg = try Bleach.Html.sanitizeAlloc(a, c.body),
        .author = c.author.name,
        .commit_parent = parents,
    };
}

fn buildList(
    a: Allocator,
    repo: Git.Repo,
    name: []const u8,
    before: ?Git.SHA,
    count: usize,
    outsha: *Git.SHA,
) ![]S.Commits {
    return buildListBetween(a, repo, name, null, before, count, outsha);
}

fn buildListBetween(
    a: Allocator,
    repo: Git.Repo,
    name: []const u8,
    left: ?Git.SHA,
    right: ?Git.SHA,
    count: usize,
    outsha: *Git.SHA,
) ![]S.Commits {
    var commits = try a.alloc(S.Commits, count);
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
        c.* = try commitVerse(a, current, name);
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

pub fn commitsView(ctx: *Verse.Frame) Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;

    if (ctx.uri.next()) |next| {
        if (!std.mem.eql(u8, next, "commits")) return error.Unrouteable;
    }

    var commitish: ?Git.SHA = null;
    if (ctx.uri.next()) |next| if (eql(u8, next, "before")) {
        if (ctx.uri.next()) |before| commitish = Git.SHA.initPartial(before);
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

    const filename = try std.fmt.allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    var cwd = std.fs.cwd();
    const dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = Git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;
    defer repo.raze();

    var last_sha: Git.SHA = undefined;
    const cmts_list = buildList(ctx.alloc, repo, rd.name, commitish, 50, &last_sha) catch
        return error.Unknown;

    return sendCommits(ctx, cmts_list, rd.name, last_sha.hex[0..8]);
}

pub fn commitsBefore(ctx: *Verse.Frame) Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;

    std.debug.assert(std.mem.eql(u8, "after", ctx.uri.next().?));

    const filename = try std.fmt.allocPrint(ctx.alloc, "./repos/{s}", .{rd.name});
    var cwd = std.fs.cwd();
    const dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = Git.Repo.init(dir) catch return error.Unknown;
    repo.loadData(ctx.alloc) catch return error.Unknown;

    const before: Git.SHA = if (ctx.uri.next()) |bf| Git.SHA.initPartial(bf);
    const commits_b = try ctx.alloc.alloc(Template.Verse, 50);
    var last_sha: Git.SHA = undefined;
    const cmts_list = try buildList(ctx.alloc, repo, rd.name, before, commits_b, &last_sha);
    return sendCommits(ctx, cmts_list, rd.name, last_sha[0..]);
}

fn sendCommits(ctx: *Verse.Frame, list: []const S.Commits, repo_name: []const u8, sha: []const u8) Error!void {
    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };

    var page = CommitsListPage.init(.{
        .meta_head = meta_head,
        .body_header = .{ .nav = .{
            .nav_buttons = &try Repos.navButtons(ctx),
        } },

        .commits = list,
        .after_commits = .{
            .repo_name = repo_name,
            .sha = sha,
        },
    });

    try ctx.sendPage(&page);
}
