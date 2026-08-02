pub fn treeBlob(frame: *Frame) Router.Error!void {
    const rd = RouteData.init(frame.uri) orelse return error.ServerFault;
    _ = frame.uri.next();

    const vis: Repo.Visibility.Select = if (frame.user) |_| .all else .public_only;
    var repo = (repos.open(rd.name, vis, frame.io) catch return error.Unknown) orelse return error.ServerFault;
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
        const sha: Git.Sha = .init(rd.ref.?);
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
    var files: Git.Tree = (cmt.loadTree(repo, frame.alloc, frame.io) catch return error.Unknown);
    const verb = rd.verb orelse return treeEndpoint(frame, rd, repo, &files);
    var path = rd.path orelse return treeEndpoint(frame, rd, repo, &files);

    switch (verb) {
        .blob => return blob(frame, rd, repo, files),
        .tree => {
            if (!frame.uri.isDir()) {
                const uri = try allocPrint(frame.alloc, "/{s}/", .{frame.uri.path});
                return frame.redirect(uri, .permanent_redirect);
            }
            var child = files.descend(path.path[path.index..], repo, frame.alloc, frame.io) catch |err| {
                log.err("unable to descend '{s}' err {}", .{ path.path[path.index..], err });
                return error.Unknown;
            };
            return treeEndpoint(frame, rd, repo, &child);
        },
        else => {},
    }
    return treeEndpoint(frame, rd, repo, &files);
}

const BlobPage = PageData("blob.html");

fn blob(f: *Frame, rd: RouteData, repo: *Git.Repo, tree: Git.Tree) Router.Error!void {
    var path = rd.path orelse return error.InvalidURI;
    var path_itr = std.fs.path.componentIterator(path.path);
    const blob_name = path_itr.last().?.name;
    const blob_path = path_itr.path[0..path_itr.start_index];
    const blb = tree.descendBlob(path.path[path.index..], repo, f.alloc, f.io) catch unreachable;

    var resolve = repo.loadBlob(blb.sha, f.alloc, f.io) catch return error.ServerFault;
    if (!resolve.isFile()) return error.Unknown;
    const colored_blob: []const u8 = if (Highlight.Language.guessFromFilename(blb.name)) |lang|
        Highlight.highlight(lang, resolve.bytes, f.alloc, f.io) catch |err| B: {
            log.warn("unable to add syntax highlighting because {}", .{err});
            break :B resolve.bytes;
        }
    else if (excludedExt(blb.name))
        "This file type is currently unsupported"
    else
        try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = resolve.bytes }});

    const wrapped = try wrapLineNumbers(f.alloc, colored_blob);

    const upstream: ?S.BaseRepoHeaderHtml.Upstream = if (repo.findRemote("upstream")) |up| .{
        .href = .safe(try allocPrint(f.alloc, "{f}", .{std.fmt.alt(up, .formatLink)})),
    } else null;

    const safe_name = try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = blob_name }});
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
    while (itr.next()) |b| if (!b.isFile()) {
        const tree_str = "<span class=\"tree\"><a href=\"/repo/{s}/tree/{s}{s}/\">{s}</a></span>\n";
        try w.writer.print(tree_str, .{
            rd.name,
            blob_path,
            b.name,
            b.name,
        });
    };
    itr = local_tree.iterate();
    while (itr.next()) |b| if (b.isFile()) {
        const blob_str = "<span class=\"file\"><a href=\"/repo/{s}/tree/{s}{s}\">{s}</a></span>\n";
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
    const rd = RouteData.init(f.uri) orelse return error.ServerFault;
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
const repos = @import("../../repos.zig");
const Repo = @import("../../Repo.zig");
const Git = @import("../../git.zig");
const Highlight = @import("../../syntax-highlight.zig");
