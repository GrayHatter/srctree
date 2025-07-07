const BlobPage = PageData("blob.html");

pub fn treeBlob(frame: *Frame) Router.Error!void {
    const rd = RouteData.make(&frame.uri) orelse return error.Unrouteable;
    _ = frame.uri.next();

    var repo = (repos.open(rd.name, .public) catch return error.Unknown) orelse return error.Unrouteable;
    repo.loadData(frame.alloc) catch return error.Unknown;
    defer repo.raze();

    const ograph: S.OpenGraph = .{
        .title = rd.name,
        .desc = desc: {
            var d = repo.description(frame.alloc) catch return error.Unknown;
            if (startsWith(u8, d, "Unnamed repository; edit this file")) {
                d = try allocPrint(
                    frame.alloc,
                    "An Indescribable repo with {s} commits",
                    .{"[todo count commits]"},
                );
            }
            break :desc d;
        },
    };
    _ = ograph;

    const cmt = repo.headCommit(frame.alloc) catch return newRepo(frame);
    return treeOrBlobAtRef(frame, rd, cmt, &repo);
}

fn treeOrBlobAtRef(frame: *Frame, rd: RouteData, cmt: Git.Commit, repo: *Git.Repo) Router.Error!void {
    if (rd.verb) |verb| {
        if (eql(u8, verb, "blob")) {
            const files: Git.Tree = cmt.mkTree(frame.alloc, repo) catch return error.Unknown;
            return blob(frame, repo, files);
        } else if (eql(u8, verb, "tree")) {
            if (frame.uri.buffer[frame.uri.buffer.len - 1] != '/') {
                const uri = try allocPrint(frame.alloc, "/{s}/", .{frame.uri.buffer});
                return frame.redirect(uri, .permanent_redirect);
            }
            var files: Git.Tree = cmt.mkTree(frame.alloc, repo) catch return error.Unknown;
            files = mkTree(frame.alloc, repo, &frame.uri, files) catch return error.Unknown;
            return treeEndpoint(frame, repo, &files);
        } else if (eql(u8, verb, "")) {
            var files: Git.Tree = cmt.mkTree(frame.alloc, repo) catch return error.Unknown;
            return treeEndpoint(frame, repo, &files);
        } else return error.InvalidURI;
    } else {
        var files: Git.Tree = cmt.mkTree(frame.alloc, repo) catch return error.Unknown;
        return treeEndpoint(frame, repo, &files);
    }
}

fn mkTree(a: Allocator, repo: *const Git.Repo, uri: *Router.UriIterator, in_tree: Git.Tree) !Git.Tree {
    const udir = uri.next() orelse return in_tree;
    if (udir.len == 0) return in_tree;
    for (in_tree.blobs) |obj| {
        if (std.mem.eql(u8, udir, obj.name)) {
            return switch (try repo.loadObject(a, obj.sha)) {
                .tree => |t| try mkTree(a, repo, uri, t),
                else => return error.NotATree,
            };
        }
    }
    return error.InvalidURI;
}

fn blob(vrs: *Frame, repo: *Git.Repo, tree: Git.Tree) Router.Error!void {
    var blb: Git.Blob = undefined;

    var files = tree;
    search: while (vrs.uri.next()) |bname| {
        for (files.blobs) |obj| {
            if (std.mem.eql(u8, bname, obj.name)) {
                blb = obj;
                if (obj.isFile()) {
                    if (vrs.uri.next() != null) return error.InvalidURI;
                    break :search;
                }
                files = switch (repo.loadObject(vrs.alloc, obj.sha) catch return error.Unknown) {
                    .tree => |t| t,
                    else => return error.Unknown,
                };
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

const treeEndpoint = @import("tree.zig").tree;
const repos_ = @import("../repos.zig");
const RouteData = repos_.RouteData;

const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;

const verse = @import("verse");
const Frame = verse.Frame;
const S = verse.template.Structs;
const PageData = verse.template.PageData;
const Router = verse.Router;
const repos = @import("../../repos.zig");
const Git = @import("../../git.zig");
const Highlight = @import("../../syntax-highlight.zig");
