pub fn treeBlob(frame: *Frame) Router.Error!void {
    const rd = RouteData.init(frame.uri) orelse return error.Unrouteable;
    _ = frame.uri.next();

    var repo = (repos.open(rd.name, .public, frame.io) catch return error.Unknown) orelse return error.Unrouteable;
    repo.loadData(frame.alloc, frame.io) catch return error.Unknown;
    defer repo.raze(frame.alloc, frame.io);

    const ograph: S.OpenGraph = .{
        .title = rd.name,
        .desc = desc: {
            var d = repo.description(frame.alloc, frame.io) catch return error.Unknown;
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

    const cmt = repo.headCommit(frame.alloc, frame.io) catch return newRepo(frame);

    if (rd.verb != null and rd.ref != null and rd.verb.? == .ref and isHash(rd.ref.?)) {
        if (rd.ref.?.len != 40) return error.InvalidURI;
        const sha: Git.SHA = .init(rd.ref.?);
        switch (repo.objects.load(sha, frame.alloc, frame.io) catch return error.InvalidURI) {
            .commit => |c| return treeOrBlobAtRef(frame, rd, &repo, c),
            else => return error.DataInvalid,
        }
    }

    return treeOrBlobAtRef(frame, rd, &repo, cmt);
}

fn isHash(slice: []const u8) bool {
    for (slice) |s| switch (s) {
        '0'...'9', 'A'...'F', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn treeOrBlobAtRef(frame: *Frame, rd: RouteData, repo: *Git.Repo, cmt: Git.Commit) Router.Error!void {
    var files: Git.Tree = cmt.loadTree(repo, frame.alloc, frame.io) catch return error.Unknown;
    const verb = rd.verb orelse return treeEndpoint(frame, rd, repo, &files);
    var path = rd.path orelse return treeEndpoint(frame, rd, repo, &files);

    switch (verb) {
        .blob => return blob(frame, rd, repo, files),
        .tree => {
            if (frame.uri.buffer[frame.uri.buffer.len - 1] != '/') {
                const uri = try allocPrint(frame.alloc, "/{s}/", .{frame.uri.buffer});
                return frame.redirect(uri, .permanent_redirect);
            }
            files = traverseTree(repo, &path, files, frame.alloc, frame.io) catch return error.Unknown;
            return treeEndpoint(frame, rd, repo, &files);
        },
        else => {},
    }
    return treeEndpoint(frame, rd, repo, &files);
}

fn traverseTree(repo: *const Git.Repo, uri: *verse.Uri.Iterator, in_tree: Git.Tree, a: Allocator, io: Io) !Git.Tree {
    const udir = uri.next() orelse return in_tree;
    if (udir.len == 0) return in_tree;
    for (in_tree.blobs) |obj| {
        if (std.mem.eql(u8, udir, obj.name)) {
            return switch (try repo.objects.load(obj.sha, a, io)) {
                .tree => |t| try traverseTree(repo, uri, t, a, io),
                else => return error.NotATree,
            };
        }
    }
    return error.InvalidURI;
}

const BlobPage = PageData("blob.html");

fn blob(frame: *Frame, rd: RouteData, repo: *Git.Repo, tree: Git.Tree) Router.Error!void {
    var blb: Git.Blob = undefined;
    var files = tree;
    var path = rd.path orelse return error.InvalidURI;
    search: while (path.next()) |bname| {
        for (files.blobs) |obj| {
            if (std.mem.eql(u8, bname, obj.name)) {
                blb = obj;
                if (obj.isFile()) {
                    if (path.next() != null) return error.InvalidURI;
                    break :search;
                }
                files = switch (repo.objects.load(obj.sha, frame.alloc, frame.io) catch return error.Unknown) {
                    .tree => |t| t,
                    else => return error.Unknown,
                };
                continue :search;
            }
        } else return error.InvalidURI;
    }

    var resolve = repo.loadBlob(blb.sha, frame.alloc, frame.io) catch return error.Unknown;
    if (!resolve.isFile()) return error.Unknown;
    const formatted: []const u8 = if (Highlight.Language.guessFromFilename(blb.name)) |lang|
        try Highlight.highlight(frame.alloc, lang, resolve.data.?)
    else if (excludedExt(blb.name))
        "This file type is currently unsupported"
    else
        allocPrint(frame.alloc, "{f}", .{abx.Html{ .text = resolve.data.? }}) catch return error.Unknown;

    const wrapped = try wrapLineNumbers(frame.alloc, formatted);

    const upstream: ?S.Upstream = if (repo.findRemote("upstream")) |up| .{
        .href = try allocPrint(frame.alloc, "{f}", .{std.fmt.alt(up, .formatLink)}),
    } else null;

    var page = BlobPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = frame.response_data.get(S.BodyHeaderHtml).?.*,
        .tree_blob_header = .{
            .blame = .{
                .repo_name = rd.name,
                .filename = path.buffer,
            },
            .git_uri = .{
                .host = "srctree.gr.ht",
                .repo_name = rd.name,
            },
            .repo_name = rd.name,
            .upstream = upstream,
        },
        .filename = blb.name,
        .numbered_lines = wrapped,
    });

    try frame.sendPage(&page);
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

fn wrapLineNumbers(a: Allocator, text: []const u8) ![]S.NumberedLines {
    var litr = splitScalar(u8, text, '\n');
    const count = std.mem.count(u8, text, "\n");
    const lines = try a.alloc(S.NumberedLines, count + 1);
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
const Io = std.Io;
const allocPrint = std.fmt.allocPrint;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;

const verse = @import("verse");
const abx = verse.abx;
const Frame = verse.Frame;
const S = verse.template.Structs;
const PageData = verse.template.PageData;
const Router = verse.Router;
const repos = @import("../../repos.zig");
const Git = @import("../../git.zig");
const Highlight = @import("../../syntax-highlight.zig");
