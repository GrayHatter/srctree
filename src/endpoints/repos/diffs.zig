const std = @import("std");
const Allocator = std.mem.Allocator;
const allocPrint = std.fmt.allocPrint;

const Commits = @import("commits.zig");

const Repo = @import("../repos.zig");

const Bleach = @import("../../bleach.zig");
const CURL = @import("../../curl.zig");
const Context = @import("../../context.zig");
const DOM = @import("../../dom.zig");
const HTML = @import("../../html.zig");
const Humanize = @import("../../humanize.zig");
const Patch = @import("../../patch.zig");
const Response = @import("../../response.zig");
const Route = @import("../../routes.zig");
const Template = @import("../../template.zig");
const Types = @import("../../types.zig");
const UserData = @import("../../request_data.zig").UserData;

const Comment = Types.Comment;
const Delta = Types.Delta;
const Error = Route.Error;
const GET = Route.GET;
const POST = Route.POST;
const ROUTE = Route.ROUTE;
const S = Template.Structs;
const Thread = Types.Thread;
const UriIter = Route.UriIter;

pub const routes = [_]Route.Match{
    ROUTE("", list),
    GET("new", new),
    POST("new", newPost),
    POST("add-comment", newComment),
};

fn isHex(input: []const u8) ?usize {
    for (input) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return std.fmt.parseInt(usize, input, 16) catch null;
}

pub fn router(ctx: *Context) Error!Route.Callable {
    std.debug.assert(std.mem.eql(u8, "diffs", ctx.uri.next().?));
    const verb = ctx.uri.peek() orelse return Route.router(ctx, &routes);

    if (isHex(verb)) |_| {
        return view;
    }

    return Route.router(ctx, &routes);
}

fn new(ctx: *Context) Error!void {
    var tmpl = comptime Template.find("diff-new.html");
    try ctx.sendTemplate(&tmpl);
}

fn inNetwork(str: []const u8) bool {
    if (!std.mem.startsWith(u8, str, "https://srctree.gr.ht")) return false;
    for (str) |c| if (c == '@') return false;
    return true;
}

const IssueCreateReq = struct {
    patch_uri: []const u8,
    title: []const u8,
    desc: []const u8,
    //action: ?union(enum) {
    //    submit: bool,
    //    preview: bool,
    //},

};

fn newPost(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    if (ctx.req_data.post_data) |post| {
        const udata = UserData(IssueCreateReq).init(post) catch return error.BadData;

        var delta = Delta.new(rd.name) catch unreachable;
        //delta.src = src;
        delta.title = udata.title;
        delta.message = udata.desc;
        delta.attach = .{ .diff = 0 };
        delta.commit() catch unreachable;

        if (inNetwork(udata.patch_uri)) {
            std.debug.print("src {s}\ntitle {s}\ndesc {s}\naction {s}\n", .{
                udata.patch_uri,
                udata.title,
                udata.desc,
                "unimplemented",
            });
            const data = Patch.loadRemote(ctx.alloc, udata.patch_uri) catch unreachable;
            const filename = std.fmt.allocPrint(
                ctx.alloc,
                "data/patch/{s}.{x}.patch",
                .{ rd.name, delta.index },
            ) catch unreachable;
            var file = std.fs.cwd().createFile(filename, .{}) catch unreachable;
            defer file.close();
            file.writer().writeAll(data.blob) catch unreachable;
        }
        var buf: [2048]u8 = undefined;
        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/diffs/{x}", .{ rd.name, delta.index });
        return ctx.response.redirect(loc, true) catch unreachable;
    }

    var tmpl = Template.find("diff-new.html");
    try ctx.sendTemplate(&tmpl);
}

fn newComment(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    var buf: [2048]u8 = undefined;
    if (ctx.req_data.post_data) |post| {
        var valid = post.validator();
        const delta_id = try valid.require("did");
        const delta_index = isHex(delta_id.value) orelse return error.Unrouteable;
        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/diffs/{x}", .{ rd.name, delta_index });

        const msg = try valid.require("comment");
        if (msg.value.len < 2) return ctx.response.redirect(loc, true) catch unreachable;

        var delta = Delta.open(ctx.alloc, rd.name, delta_index) catch unreachable orelse return error.Unrouteable;
        const username = if (ctx.auth.valid())
            (ctx.auth.user(ctx.alloc) catch unreachable).username
        else
            "public";
        const c = Comment.new(username, msg.value) catch unreachable;
        _ = delta.loadThread(ctx.alloc) catch unreachable;
        delta.addComment(ctx.alloc, c) catch unreachable;
        delta.commit() catch unreachable;
        return ctx.response.redirect(loc, true) catch unreachable;
    }
    return error.Unknown;
}

pub fn patchStruct(a: Allocator, patch: *Patch.Patch) !Template.Structs.PatchHtml {
    patch.parse(a) catch |err| {
        if (std.mem.indexOf(u8, patch.blob, "\nMerge: ") == null) {
            std.debug.print("err: {any}\n", .{err});
            std.debug.print("'''\n{s}\n'''\n", .{patch.blob});
            return err;
        } else {
            std.debug.print("Unable to parse diff {} (merge commit)\n", .{err});
            return error.UnableToGeneratePatch;
        }
    };

    const diffs = patch.diffs orelse unreachable;
    const files = try a.alloc(Template.Structs.Files, diffs.len);
    errdefer a.free(files);
    for (diffs, files) |diff, *file| {
        const body = diff.changes orelse continue;

        const dstat = patch.patchStat();
        const stat = try allocPrint(
            a,
            "added: {}, removed: {}, total {}",
            .{ dstat.additions, dstat.deletions, dstat.total },
        );
        const html_lines = Patch.diffLineHtml(a, body);
        const diff_lines = try a.alloc([]u8, html_lines.len);
        for (diff_lines, html_lines) |*dline, hline| {
            dline.* = try allocPrint(a, "{}", .{hline});
        }
        file.* = .{
            .diff_stat = stat,
            .filename = if (diff.filename) |name|
                try allocPrint(a, "{s}", .{name})
            else
                try allocPrint(a, "{s} was Deleted", .{"filename"}),
            .diff_lines = diff_lines,
        };
    }
    return .{
        .files = files,
    };
}

pub fn patchHtml(a: Allocator, patch: *Patch.Patch) ![]HTML.Element {
    patch.parse(a) catch |err| {
        if (std.mem.indexOf(u8, patch.blob, "\nMerge: ") == null) {
            std.debug.print("err: {any}\n", .{err});
            std.debug.print("'''\n{s}\n'''\n", .{patch.blob});
            return err;
        } else {
            std.debug.print("Unable to parse diff {} (merge commit)\n", .{err});
            return &[0]HTML.Element{};
        }
    };

    const diffs = patch.diffs orelse unreachable;

    var dom = DOM.new(a);

    dom = dom.open(HTML.patch());
    for (diffs) |diff| {
        const body = diff.changes orelse continue;

        const dstat = patch.patchStat();
        const stat = try std.fmt.allocPrint(
            a,
            "added: {}, removed: {}, total {}",
            .{ dstat.additions, dstat.deletions, dstat.total },
        );
        dom.push(HTML.element("diffstat", stat, null));
        dom = dom.open(HTML.diff());

        dom.push(HTML.element(
            "filename",
            if (diff.filename) |name|
                try std.fmt.allocPrint(a, "{s}", .{name})
            else
                try std.fmt.allocPrint(a, "{s} was Deleted", .{"filename"}),
            null,
        ));
        dom = dom.open(HTML.element("changes", null, null));
        dom.pushSlice(Patch.diffLineHtml(a, body));
        dom = dom.close();
        dom = dom.close();
    }
    dom = dom.close();
    return dom.done();
}

const PatchView = struct {
    @"inline": ?bool = true,
};

const DiffViewPage = Template.PageData("delta-diff.html");

fn view(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    const delta_id = ctx.uri.next().?;
    const index = isHex(delta_id) orelse return error.Unrouteable;

    var delta = Delta.open(ctx.alloc, rd.name, index) catch |err| switch (err) {
        error.InvalidTarget => return error.Unrouteable,
        error.InputOutput => unreachable,
        error.Other => unreachable,
        else => unreachable,
    } orelse return error.Unrouteable;

    const patch_header = S.Header{
        .title = Bleach.sanitizeAlloc(ctx.alloc, delta.title, .{}) catch unreachable,
        .message = Bleach.sanitizeAlloc(ctx.alloc, delta.message, .{}) catch unreachable,
    };

    // meme saved to protect history
    //for ([_]Comment{ .{
    //    .author = "grayhatter",
    //    .message = "Wow, srctree's Diff view looks really good!",
    //}, .{
    //    .author = "robinli",
    //    .message = "I know, it's clearly the best I've even seen. Soon it'll even look good in Hastur!",
    //} }) |cm| {
    //    comments.pushSlice(addComment(ctx.alloc, cm) catch unreachable);
    //}

    _ = delta.loadThread(ctx.alloc) catch unreachable;

    var comments_: []Template.Structs.Comments = &[0]Template.Structs.Comments{};
    if (delta.getComments(ctx.alloc)) |comments| {
        comments_ = try ctx.alloc.alloc(Template.Structs.Comments, comments.len);
        for (comments, comments_) |comment, *c_ctx| {
            c_ctx.* = .{ .comment = .{
                .author = try Bleach.sanitizeAlloc(ctx.alloc, comment.author, .{}),
                .date = try allocPrint(ctx.alloc, "{}", .{Humanize.unix(comment.updated)}),
                .message = try Bleach.sanitizeAlloc(ctx.alloc, comment.message, .{}),
            } };
        }
    } else |err| {
        std.debug.print("Unable to load comments for thread {} {}\n", .{ index, err });
        @panic("oops");
    }

    try ctx.putContext("Delta_id", .{ .slice = delta_id });

    const udata = UserData(PatchView).init(ctx.req_data.query_data) catch return error.BadData;
    if (udata.@"inline") |_| {
        //
    } else {
        //
    }

    var patch_formatted: ?Template.Structs.PatchHtml = null;
    const filename = try std.fmt.allocPrint(ctx.alloc, "data/patch/{s}.{x}.patch", .{ rd.name, delta.index });

    if (std.fs.cwd().openFile(filename, .{})) |f| {
        const fdata = f.readToEndAlloc(ctx.alloc, 0xFFFFF) catch return error.Unknown;
        var patch = Patch.Patch.init(fdata);
        if (patchStruct(ctx.alloc, &patch)) |phtml| {
            patch_formatted = phtml;
        } else |err| {
            std.debug.print("Unable to generate patch {any}\n", .{err});
        }
        f.close();
    } else |err| {
        std.debug.print("Unable to load patch {} {s}\n", .{ err, filename });
    }

    var page = DiffViewPage.init(.{
        .meta_head = .{
            .open_graph = .{},
        },
        .body_header = .{ .nav = .{
            .nav_buttons = &try Repo.navButtons(ctx),
            .nav_auth = undefined,
        } },
        .patch = if (patch_formatted) |pf| .{
            .header = patch_header,
            .patch = pf,
        } else .{
            .header = patch_header,
            .patch = .{ .files = &[0]Template.Structs.Files{} },
        },
        .comments = comments_,
        .delta_id = delta_id,
    });

    try ctx.sendPage(&page);
}

fn list(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;

    const last = Delta.last(rd.name) + 1;
    var end: usize = 0;

    var tmpl_ctx = try ctx.alloc.alloc(Template.Context, last);
    for (0..last) |i| {
        var d = Delta.open(ctx.alloc, rd.name, i) catch continue orelse continue;
        if (!std.mem.eql(u8, d.repo, rd.name) or d.attach != .diff) {
            d.raze(ctx.alloc);
            continue;
        }

        const delta_ctx = &tmpl_ctx[end];
        delta_ctx.* = Template.Context.init(ctx.alloc);
        const builder = d.builder();
        builder.build(ctx.alloc, delta_ctx) catch unreachable;
        _ = d.loadThread(ctx.alloc) catch unreachable;
        if (d.getComments(ctx.alloc)) |cmts| {
            try delta_ctx.putSlice(
                "Comments_icon",
                try std.fmt.allocPrint(ctx.alloc, "<span class=\"icon\">\xee\xa0\x9c {}</span>", .{cmts.len}),
            );
        } else |_| unreachable;
        end += 1;
        continue;
    }
    var tmpl = Template.find("deltalist.html");
    try ctx.putContext("List", .{ .block = tmpl_ctx[0..end] });
    try ctx.sendTemplate(&tmpl);
}
