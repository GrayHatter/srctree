pub fn treeBlob(frame: *Frame) Router.Error!void {
    const rd = RouteData.init(frame.uri) orelse return error.Unrouteable;
    _ = frame.uri.next();

    const vis: repos.Visibility.Select = if (frame.user) |_| .all else .public_only;
    var repo = (repos.open(rd.name, vis, frame.io) catch return error.Unknown) orelse return error.Unrouteable;
    repo.loadData(frame.alloc, frame.io) catch return error.Unknown;
    defer repo.raze(frame.alloc, frame.io);

    const ograph: S.OpenGraph = .{
        .title = rd.name,
        .desc = repo.description(frame.alloc, frame.io) catch |err| switch (err) {
            error.DefaultDescription, error.NoDescription => try allocPrint(
                frame.alloc,
                "An Indescribable repo with {s} commits",
                .{"[todo count commits]"},
            ),
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ServerFault,
        },
    };
    _ = ograph;

    const cmt = repo.HEAD(frame.alloc, frame.io) catch return newRepo(frame);

    if (rd.verb != null and rd.ref != null and isHash(rd.ref.?)) {
        std.debug.print("ref '{s}'\n", .{rd.ref.?});
        const sha: Git.Sha = .init(rd.ref.?);
        switch (repo.objects.load(sha, frame.alloc, frame.io) catch return error.InvalidURI) {
            .commit => |c| return treeOrBlobAtRef(frame, rd, &repo, c),
            else => return error.DataInvalid,
        }
    } else std.debug.print("no ref {}\n", .{rd});

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

fn blob(f: *Frame, rd: RouteData, repo: *Git.Repo, tree: Git.Tree) Router.Error!void {
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
                files = switch (repo.objects.load(obj.sha, f.alloc, f.io) catch return error.Unknown) {
                    .tree => |t| t,
                    else => return error.Unknown,
                };
                continue :search;
            }
        } else return error.InvalidURI;
    }

    var resolve = repo.loadBlob(blb.sha, f.alloc, f.io) catch return error.ServerFault;
    if (!resolve.isFile()) return error.Unknown;
    const colored_blob: []const u8 = if (Highlight.Language.guessFromFilename(blb.name)) |lang|
        Highlight.highlight(lang, resolve.data.?, f.alloc, f.io) catch return error.ServerFault
    else if (excludedExt(blb.name))
        "This file type is currently unsupported"
    else
        try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = resolve.data.? }});

    const wrapped = try wrapLineNumbers(f.alloc, colored_blob);

    const upstream: ?S.BaseRepoHeaderHtml.Upstream = if (repo.findRemote("upstream")) |up| .{
        .href = .safe(try allocPrint(f.alloc, "{f}", .{std.fmt.alt(up, .formatLink)})),
    } else null;

    const safe_name = try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = blb.name }});
    const meta_title = try allocPrint(f.alloc, "{s} - {s} -- srctree", .{ safe_name, rd.name });
    const ext: ?[]const u8 = if (std.mem.findLast(u8, safe_name, ".")) |lst| safe_name[lst + 1 ..] else null;
    const meta_desc = try allocPrint(f.alloc, "{} lines {s}{s}", .{
        countScalar(u8, wrapped, '\n'),
        if (ext) |_| " of " else "",
        if (ext) |e| e else "",
    });

    var page = BlobPage.init(.{
        .meta_head = .{
            .title = meta_title,
            .open_graph = .{ .title = safe_name, .desc = meta_desc },
        },
        .body_header = f.response_data.get(S.BodyHeaderHtml).?.*,
        .repo_header = .{
            .repo_name = .abx(rd.name),
            // TODO FIXME
            .description = .safe(try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = repo.description(f.alloc, f.io) catch "" }})),
            .blame = .{ .repo_name = .abx(rd.name), .filename = .abx(path.buffer) },
            .git_uri = .{ .host = .safe("srctree.gr.ht"), .repo_name = .abx(rd.name) },
            .upstream = upstream,
        },
        .filename = .abx(blb.name),
        .blob_lines = wrapped,
    });

    try f.sendPage(&page);
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

fn wrapLineNumbers(a: Allocator, text: []const u8) ![]u8 {
    var r: Io.Reader = .fixed(text);
    var w: Io.Writer.Allocating = try .initCapacity(a, text.len * 2);
    var number: usize = 0;
    while (r.takeSentinel('\n')) |line| {
        number += 1;
        try w.writer.print(
            \\<ln num="{0d}" id="L{0d}">{1s}</ln>
            \\
        , .{ number, line });
    } else |err| switch (err) {
        error.EndOfStream => return try w.toOwnedSlice(),
        else => unreachable,
    }
}

const NewRepoPage = verse.template.PageData("repo-new.html");
fn newRepo(f: *Frame) Router.Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    f.status = .ok;

    //const upstream: ?S.BaseRepoHeaderHtml.Upstream = if (repo.findRemote("upstream")) |up| .{
    //    .href = try allocPrint(ctx.alloc, "{f}", .{std.fmt.alt(up, .formatLink)}),
    //} else null;
    const meta_title = try allocPrint(f.alloc, "Brand new repo {s} on srctree", .{rd.name});
    var page: NewRepoPage = .init(.{
        .meta_head = .{
            .title = meta_title,
            .open_graph = .{ .title = rd.name, .desc = "" },
        },
        .body_header = f.response_data.get(S.BodyHeaderHtml).?.*,
        .repo_header = .{
            .repo_name = .abx(rd.name),
            .description = .safe(""),
            .git_uri = .{
                .host = .safe("srctree.gr.ht"),
                .repo_name = .abx(rd.name),
            },
            .upstream = null,
            .blame = null,
        },
    });
    try f.sendPage(&page);
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
const countScalar = std.mem.countScalar;

const verse = @import("verse");
const abx = verse.abx;
const Frame = verse.Frame;
const S = verse.template.Structs;
const PageData = verse.template.PageData;
const Router = verse.Router;
const repos = @import("../../repos.zig");
const Git = @import("../../git.zig");
const Highlight = @import("../../syntax-highlight.zig");
