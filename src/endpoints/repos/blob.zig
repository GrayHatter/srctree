pub fn treeBlob(f: *Frame) Router.Error!void {
    const rd = RouteData.init(f) orelse return error.ServerFault;
    _ = f.uri.next();

    const vis: Repo.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo = (Repo.openGit(rd.name, vis, f.io) catch return error.Unknown) orelse return error.ServerFault;
    repo.loadData(f.alloc, f.io) catch return error.Unknown;
    defer repo.raze(f.alloc, f.io);

    const ograph: S.OpenGraph = .{
        .title = rd.name,
        .desc = repo.description(f.alloc, f.io) catch |err| switch (err) {
            error.DefaultDescription, error.NoDescription => try allocPrint(
                f.alloc,
                "An Indescribable repo with {s} commits",
                .{"[todo count commits]"},
            ),
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ServerFault,
        },
    };
    _ = ograph;

    const cmt = repo.HEAD(f.alloc, f.io) catch return newRepo(f);

    if (rd.verb != null and rd.ref != null and isHash(rd.ref.?)) {
        const sha: Git.Sha = .init(rd.ref.?);
        switch (repo.objects.load(sha, f.alloc, f.io) catch return error.InvalidURI) {
            .commit => |c| return treeOrBlobAtRef(f, rd, &repo, c),
            else => return error.DataInvalid,
        }
    }

    return treeOrBlobAtRef(f, rd, &repo, cmt);
}

fn isHash(slice: []const u8) bool {
    for (slice) |s| switch (s) {
        '0'...'9', 'A'...'F', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn treeOrBlobAtRef(f: *Frame, rd: RouteData, repo: *Git.Repo, cmt: Git.Commit) Router.Error!void {
    var files: Git.Tree = (cmt.loadTree(repo, f.alloc, f.io) catch return error.Unknown);
    const verb = rd.verb orelse return treeEndpoint(f, rd, repo, &files);
    var path = rd.path orelse return treeEndpoint(f, rd, repo, &files);

    switch (verb) {
        .blob => return blobHtml(f, rd, repo, files),
        .tree => {
            if (!f.uri.isDir()) {
                const uri = try allocPrint(f.alloc, "/{s}/", .{f.uri.path});
                return f.redirect(uri, .permanent_redirect);
            }
            var child = files.descend(path.path[path.index..], repo, f.alloc, f.io) catch |err| {
                log.err("unable to descend '{s}' err {}", .{ path.path[path.index..], err });
                return error.NotFound;
            };
            return treeEndpoint(f, rd, repo, &child);
        },
        else => {},
    }
    return treeEndpoint(f, rd, repo, &files);
}

const BlobPage = PageData("blob.html");

fn getBlob(f: *Frame, rd: RouteData, repo: *Git.Repo, tree: Git.Tree) Router.Error!Git.Blob {
    var path = rd.path orelse return error.InvalidURI;
    var path_itr = std.fs.path.componentIterator(path.path);
    const blob_name = path_itr.last().?.name;
    //const blob_path = path_itr.path[0..path_itr.start_index];
    const blb = tree.descendBlob(path.path[path.index..], repo, f.alloc, f.io) catch |err| {
        log.err("unable to descend to blob {}", .{err});
        return error.NotFound;
    };

    var resolve = repo.loadBlob(blb.sha, f.alloc, f.io) catch return error.ServerFault;
    resolve.name = blob_name;
    return switch (resolve.data) {
        .blob => resolve,
        .tree => error.NotFound,
        .unloaded => error.ServerFault,
    };
}

fn blobHtml(f: *Frame, rd: RouteData, repo: *Git.Repo, tree: Git.Tree) Router.Error!void {
    const path = rd.path orelse return error.InvalidURI;
    var path_itr = std.fs.path.componentIterator(path.path);
    _ = path_itr.last().?.name;
    const blob_path = path_itr.path[0..path_itr.start_index];

    const blob_data = try getBlob(f, rd, repo, tree);
    const colored_blob: []const u8 = if (Highlight.Language.guessFromFilename(blob_data.name)) |lang|
        Highlight.highlight(lang, blob_data.data.blob, f.alloc, f.io) catch |err| B: {
            log.warn("unable to add syntax highlighting because {}", .{err});
            break :B blob_data.data.blob;
        }
    else if (excludedExt(blob_data.name))
        "This file type is currently unsupported"
    else
        try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = blob_data.data.blob }});

    const wrapped = try wrapLineNumbers(f.alloc, colored_blob);

    const upstream: ?S.BaseRepoHeaderHtml.Upstream = if (repo.findRemote("upstream")) |up| .{
        .href = .safe(try allocPrint(f.alloc, "{f}", .{std.fmt.alt(up, .formatLink)})),
    } else null;

    const safe_name = try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = blob_data.name }});
    const meta_title = try allocPrint(f.alloc, "{s} - {s} -- srctree", .{ safe_name, rd.name });
    const ext: ?[]const u8 = if (std.mem.findLast(u8, safe_name, ".")) |lst| safe_name[lst + 1 ..] else null;
    const meta_desc = try allocPrint(f.alloc, "{} lines {s}{s}", .{
        countScalar(u8, wrapped, '\n'),
        if (ext) |_| " of " else "",
        if (ext) |e| e else "",
    });

    var w: Io.Writer.Allocating = .init(f.alloc);
    const local_tree = tree.descend(blob_path, repo, f.alloc, f.io) catch |e| switch (e) {
        error.CurrentTree => tree,
        else => return error.ServerFault,
    };
    var itr = local_tree.iterate();
    while (itr.next()) |b| if (b.data != .blob) {
        const tree_str = "<span class=\"tree\"><a href=\"/repo/{s}/tree/{s}{s}/\">{s}</a></span>\n";
        try w.writer.print(tree_str, .{
            rd.name,
            blob_path,
            b.name,
            b.name,
        });
    };
    itr = local_tree.iterate();
    while (itr.next()) |b| if (b.data == .blob) {
        const blob_str = "<span class=\"file\"><a href=\"/repo/{s}/blob/{s}{s}\">{s}</a></span>\n";
        try w.writer.print(blob_str, .{
            rd.name,
            blob_path,
            b.name,
            b.name,
        });
    };

    var page = BlobPage.init(.{
        .meta_head = .{
            .title = meta_title,
            .open_graph = .{ .title = safe_name, .desc = meta_desc },
        },
        .body_header = f.response_data.get(S.BodyHeaderHtml).?.*,
        .repo_header = .{
            .repo_name = .abx(rd.name),
            .description = .abx(repo.description(f.alloc, f.io) catch ""),
            .blame = .{ .repo_name = .safe(rd.name), .filename = .abx(path.path) },
            .git_uri = .{ .host = .safe(try f.request.host.?.valid()), .repo_name = .abx(rd.name) },
            .upstream = upstream,
        },
        .tree_view = .safe(w.written()),
        .filename = .abx(blob_data.name),
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
    const rd = RouteData.init(f) orelse return error.ServerFault;
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
            .git_uri = .{ .host = .safe(try (f.request.host orelse return error.DataMissing).valid()), .repo_name = .abx(rd.name) },
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
const log = std.log.scoped(.endpoint_blob);

const verse = @import("verse");
const abx = verse.Antibiotic;
const Frame = verse.Frame;
const S = verse.template.Structs;
const PageData = verse.template.PageData;
const Router = verse.Router;
const Repo = @import("../../Repo.zig");
const Git = @import("../../git.zig");
const Highlight = @import("../../syntax-highlight.zig");
