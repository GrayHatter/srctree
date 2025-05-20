const BlobPage = PageData("blob.html");

pub fn treeBlob(ctx: *Frame) Router.Error!void {
    const rd = RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    _ = ctx.uri.next();

    var repo = (repos.open(rd.name, .public) catch return error.Unknown) orelse return error.Unrouteable;
    repo.loadData(ctx.alloc) catch return error.Unknown;
    defer repo.raze();

    const ograph: S.OpenGraph = .{
        .title = rd.name,
        .desc = desc: {
            var d = repo.description(ctx.alloc) catch return error.Unknown;
            if (startsWith(u8, d, "Unnamed repository; edit this file")) {
                d = try allocPrint(
                    ctx.alloc,
                    "An Indescribable repo with {s} commits",
                    .{"[todo count commits]"},
                );
            }
            break :desc d;
        },
    };

    _ = ograph;
    const cmt = repo.headCommit(ctx.alloc) catch return newRepo(ctx);
    if (rd.verb) |verb| {
        if (eql(u8, verb, "blob")) {
            const files: Git.Tree = cmt.mkTree(ctx.alloc, &repo) catch return error.Unknown;
            return blob(ctx, &repo, files);
        } else if (eql(u8, verb, "tree")) {
            var files: Git.Tree = cmt.mkTree(ctx.alloc, &repo) catch return error.Unknown;
            files = mkTree(ctx.alloc, &repo, &ctx.uri, files) catch return error.Unknown;
            return repos_.tree(ctx, &repo, &files);
        } else if (eql(u8, verb, "")) {
            var files: Git.Tree = cmt.mkTree(ctx.alloc, &repo) catch return error.Unknown;
            return repos_.tree(ctx, &repo, &files);
        } else return error.InvalidURI;
    } else {
        var files: Git.Tree = cmt.mkTree(ctx.alloc, &repo) catch return error.Unknown;
        return repos_.tree(ctx, &repo, &files);
    }
}

fn mkTree(a: Allocator, repo: *const Git.Repo, uri: *Router.UriIterator, pfiles: Git.Tree) !Git.Tree {
    var files: Git.Tree = pfiles;
    if (uri.next()) |udir| for (files.blobs) |obj| {
        if (std.mem.eql(u8, udir, obj.name)) {
            const treeobj = try repo.loadObject(a, obj.sha);
            files = try Git.Tree.initOwned(obj.sha, a, treeobj);
            return try mkTree(a, repo, uri, files);
        }
    };
    return files;
}

fn blob(vrs: *Frame, repo: *Git.Repo, pfiles: Git.Tree) Router.Error!void {
    var blb: Git.Blob = undefined;

    var files = pfiles;
    search: while (vrs.uri.next()) |bname| {
        for (files.blobs) |obj| {
            if (std.mem.eql(u8, bname, obj.name)) {
                blb = obj;
                if (obj.isFile()) {
                    if (vrs.uri.next()) |_| return error.InvalidURI;
                    break :search;
                }
                const treeobj = repo.loadObject(vrs.alloc, obj.sha) catch return error.Unknown;
                files = Git.Tree.initOwned(obj.sha, vrs.alloc, treeobj) catch return error.Unknown;
                continue :search;
            }
        } else return error.InvalidURI;
    }

    var resolve = repo.loadBlob(vrs.alloc, blb.sha) catch return error.Unknown;
    if (!resolve.isFile()) return error.Unknown;
    var formatted: []const u8 = undefined;
    if (Highlight.Language.guessFromFilename(blb.name)) |lang| {
        const pre = try Highlight.highlight(vrs.alloc, lang, resolve.data.?);
        formatted = pre[28..][0 .. pre.len - 38];
    } else if (excludedExt(blb.name)) {
        formatted = "This file type is currently unsupported";
    } else {
        formatted = verse.abx.Html.cleanAlloc(vrs.alloc, resolve.data.?) catch return error.Unknown;
    }

    const wrapped = try wrapLineNumbers(vrs.alloc, formatted);

    vrs.uri.reset();
    _ = vrs.uri.next();
    const uri_repo = vrs.uri.next() orelse return error.Unrouteable;
    _ = vrs.uri.next();
    const uri_filename = verse.abx.Html.cleanAlloc(vrs.alloc, vrs.uri.rest()) catch return error.Unknown;

    vrs.status = .ok;

    var btns = repos_.navButtons(vrs) catch return error.Unknown;
    // TODO fixme
    _ = &btns;

    var page = BlobPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = vrs.response_data.get(S.BodyHeaderHtml) catch return error.Unknown,
        .repo = uri_repo,
        .uri_filename = uri_filename,
        .filename = blb.name,
        .blob_lines = wrapped,
    });

    try vrs.sendPage(&page);
}

fn excludedExt(name: []const u8) bool {
    const exclude_ext = [_][:0]const u8{
        ".jpg",
        ".jpeg",
        ".gif",
        ".png",
    };
    inline for (exclude_ext) |un| {
        if (std.mem.endsWith(u8, name, un)) return true;
    }
    return false;
}

fn wrapLineNumbers(a: Allocator, text: []const u8) ![]S.BlobLines {
    // TODO

    var litr = splitScalar(u8, text, '\n');
    const count = std.mem.count(u8, text, "\n");
    const lines = try a.alloc(S.BlobLines, count + 1);
    var i: usize = 0;
    while (litr.next()) |line| {
        lines[i] = .{
            .num = i + 1,
            .line = line,
        };
        i += 1;
    }
    return lines;
}

const NewRepoPage = verse.template.PageData("repo-new.html");
fn newRepo(ctx: *Frame) Router.Error!void {
    ctx.status = .ok;

    return error.NotImplemented;
}

const repos_ = @import("../repos.zig");
const RouteData = repos_.RouteData;

const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
//const bPrint = std.fmt.bufPrint;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;

const verse = @import("verse");
const Frame = verse.Frame;
const S = verse.template.Structs;
//const template = verse.template;
const PageData = verse.template.PageData;
//const html = template.html;
//const DOM = html.DOM;
const Router = verse.Router;
//const elm = html.element;
//const Error = Router.Error;
//const ROUTE = Router.ROUTE;
//const POST = Router.POST;
//const GET = Router.GET;
//const RequestData = verse.RequestData.RequestData;
//
//const Humanize = @import("../humanize.zig");
//const Ini = @import("../ini.zig");
const repos = @import("../../repos.zig");
const Git = @import("../../git.zig");
const Highlight = @import("../../syntax-highlight.zig");
//
//const Commits = @import("repos/commits.zig");
//const Diffs = @import("repos/diffs.zig");
//const Issues = @import("repos/issues.zig");
//const htmlCommit = Commits.htmlCommit;
//
//const Types = @import("../types.zig");
//
//const gitweb = @import("../gitweb.zig");
