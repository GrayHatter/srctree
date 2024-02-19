const std = @import("std");

const Allocator = std.mem.Allocator;

const DOM = Endpoint.DOM;
const HTML = Endpoint.HTML;
const Endpoint = @import("../../endpoint.zig");
const Context = @import("../../context.zig");
const Response = Endpoint.Response;
const Template = Endpoint.Template;
const Error = Endpoint.Error;
const UriIter = Endpoint.Router.UriIter;

const Repo = @import("../repos.zig");

const GET = Endpoint.Router.Methods.GET;
const POST = Endpoint.Router.Methods.POST;

const CURL = @import("../../curl.zig");
const Bleach = @import("../../bleach.zig");
const Threads = Endpoint.Types.Threads;
const Deltas = Endpoint.Types.Deltas;
const Comments = Endpoint.Types.Comments;
const Comment = Comments.Comment;
const Patch = @import("../../patch.zig");

pub const routes = [_]Endpoint.Router.MatchRouter{
    .{ .name = "", .methods = GET, .match = .{ .call = list } },
    .{ .name = "new", .methods = GET, .match = .{ .call = new } },
    .{ .name = "new", .methods = POST, .match = .{ .call = newPost } },
    .{ .name = "add-comment", .methods = POST, .match = .{ .call = newComment } },
};

fn isHex(input: []const u8) ?usize {
    for (input) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return std.fmt.parseInt(usize, input, 16) catch null;
}

pub fn router(ctx: *Context) Error!Endpoint.Router.Callable {
    std.debug.assert(std.mem.eql(u8, "diffs", ctx.uri.next().?));
    const verb = ctx.uri.peek() orelse return Endpoint.Router.router(ctx, &routes);

    if (isHex(verb)) |_| {
        return view;
    }

    return Endpoint.Router.router(ctx, &routes);
}

fn new(ctx: *Context) Error!void {
    var tmpl = comptime Template.find("diff-new.html");
    tmpl.init(ctx.alloc);
    ctx.sendTemplate(&tmpl) catch unreachable;
}

fn inNetwork(str: []const u8) bool {
    if (!std.mem.startsWith(u8, str, "https://srctree.gr.ht")) return false;
    for (str) |c| if (c == '@') return false;
    return true;
}

fn newPost(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    if (ctx.response.usr_data) |usrdata| if (usrdata.post_data) |post| {
        var valid = post.validator();
        const src = try valid.require("diff source");
        const title = try valid.require("title");
        const desc = try valid.require("desc");
        const action = valid.optional("submit") orelse valid.optional("preview") orelse return error.BadData;
        var delta = Deltas.new(rd.name) catch unreachable;
        //delta.src = src;
        delta.title = title.value;
        delta.desc = desc.value;

        delta.writeOut() catch unreachable;
        if (inNetwork(src.value)) {
            std.debug.print("src {s}\ntitle {s}\ndesc {s}\naction {s}\n", .{
                src.value,
                title.value,
                desc.value,
                action.name,
            });
            var data = Patch.loadRemote(ctx.alloc, src.value) catch unreachable;
            var filename = std.fmt.allocPrint(
                ctx.alloc,
                "data/patch/{s}.{x}.patch",
                .{ rd.name, delta.index },
            ) catch unreachable;
            var file = std.fs.cwd().createFile(filename, .{}) catch unreachable;
            defer file.close();
            file.writer().writeAll(data.patch) catch unreachable;
        }
        var buf: [2048]u8 = undefined;
        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/diffs/{x}", .{ rd.name, delta.index });
        return ctx.response.redirect(loc, true) catch unreachable;
    };

    var tmpl = Template.find("diff-new.html");
    tmpl.init(ctx.alloc);
    try tmpl.addVar("diff", "new data attempting");
    ctx.sendTemplate(&tmpl) catch unreachable;
}

fn newComment(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    var buf: [2048]u8 = undefined;
    if (ctx.response.usr_data) |usrdata| if (usrdata.post_data) |post| {
        var valid = post.validator();
        const diff_id = try valid.require("diff-id");
        const diff_index = isHex(diff_id.value) orelse return error.Unrouteable;
        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/diffs/{x}", .{ rd.name, diff_index });

        const msg = try valid.require("comment");
        if (msg.value.len < 2) return ctx.response.redirect(loc, true) catch unreachable;

        var diff = Deltas.open(ctx.alloc, rd.name, diff_index) catch unreachable orelse return error.Unrouteable;
        var c = Comments.new("name", msg.value) catch unreachable;

        diff.addComment(ctx.alloc, c) catch {};
        diff.writeOut() catch unreachable;
        return ctx.response.redirect(loc, true) catch unreachable;
    };
    return error.Unknown;
}

fn addComment(a: Allocator, c: Comment) ![]HTML.Element {
    var dom = DOM.new(a);
    dom = dom.open(HTML.element("comment", null, null));

    dom = dom.open(HTML.element("context", null, null));
    dom.dupe(HTML.element(
        "author",
        &[_]HTML.E{HTML.text(Bleach.sanitizeAlloc(a, c.author, .{}) catch unreachable)},
        null,
    ));
    dom.push(HTML.element("date", "now", null));
    dom = dom.close();

    dom = dom.open(HTML.element("message", null, null));
    dom.push(HTML.text(Bleach.sanitizeAlloc(a, c.message, .{}) catch unreachable));
    dom = dom.close();

    dom = dom.close();
    return dom.done();
}

fn view(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;
    const diff_target = ctx.uri.next().?;
    const index = isHex(diff_target) orelse return error.Unrouteable;

    var tmpl = Template.find("diff-review.html");
    tmpl.init(ctx.alloc);

    var dom = DOM.new(ctx.alloc);

    var delta = Deltas.open(ctx.alloc, rd.name, index) catch |err| switch (err) {
        error.InvalidTarget => return error.Unrouteable,
        error.InputOutput => unreachable,
        error.Other => unreachable,
        else => unreachable,
    } orelse return error.Unrouteable;

    //var thread = delta.loadThread(ctx.alloc);

    //switch (diff.source) {
    //    .diff => {},
    //    .remote => @panic("Unimplemented thread source"),
    //    .issue => {
    //        var buf: [2048]u8 = undefined;
    //        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, index });
    //        return ctx.response.redirect(loc, true) catch unreachable;
    //    },
    //}

    dom = dom.open(HTML.element("context", null, null));
    dom.push(HTML.text(rd.name));
    dom = dom.open(HTML.p(null, null));
    dom.push(HTML.text(Bleach.sanitizeAlloc(ctx.alloc, delta.title, .{}) catch unreachable));
    dom = dom.close();
    dom = dom.open(HTML.p(null, null));
    dom.push(HTML.text(Bleach.sanitizeAlloc(ctx.alloc, delta.desc, .{}) catch unreachable));
    dom = dom.close();
    dom = dom.close();

    _ = try tmpl.addElements(ctx.alloc, "patch_header", dom.done());

    var comments = DOM.new(ctx.alloc);
    for ([_]Comment{ .{
        .author = "grayhatter",
        .message = "Wow, srctree's Diff view looks really good!",
    }, .{
        .author = "robinli",
        .message = "I know, it's clearly the best I've even seen. Soon it'll even look good in Hastur!",
    } }) |cm| {
        comments.pushSlice(addComment(ctx.alloc, cm) catch unreachable);
    }

    _ = delta.loadThread(ctx.alloc) catch unreachable;
    for (delta.getComments(ctx.alloc) catch unreachable) |cm| {
        comments.pushSlice(addComment(ctx.alloc, cm) catch unreachable);
    }

    _ = try tmpl.addElements(ctx.alloc, "comments", comments.done());

    const hidden = [_]HTML.Attr{
        .{ .key = "type", .value = "hidden" },
        .{ .key = "name", .value = "diff-id" },
        .{ .key = "value", .value = diff_target },
    };

    const form_data = [_]HTML.E{
        HTML.input(&hidden),
    };

    _ = try tmpl.addElements(ctx.alloc, "form-data", &form_data);

    const filename = try std.fmt.allocPrint(ctx.alloc, "data/patch/{s}.{x}.patch", .{ rd.name, delta.index });
    var file: ?std.fs.File = std.fs.cwd().openFile(filename, .{}) catch null;
    if (file) |f| {
        const fdata = f.readToEndAlloc(ctx.alloc, 0xFFFFF) catch return error.Unknown;
        const patch = try Patch.patchHtml(ctx.alloc, fdata);
        _ = try tmpl.addElementsFmt(ctx.alloc, "{pretty}", "patch", patch);
        f.close();
    } else try tmpl.addString("patch", "Patch not found");

    ctx.sendTemplate(&tmpl) catch unreachable;
}

fn list(ctx: *Context) Error!void {
    const rd = Repo.RouteData.make(&ctx.uri) orelse return error.Unrouteable;

    const last = Deltas.last(rd.name) + 1;
    var end: usize = 0;

    var tmpl_ctx = try ctx.alloc.alloc(Template.Context, last);

    for (0..last) |i| {
        var d = Deltas.open(ctx.alloc, rd.name, i) catch continue orelse continue;
        if (!std.mem.eql(u8, d.repo, rd.name)) {
            d.raze(ctx.alloc);
            continue;
        }

        const delta_ctx = &tmpl_ctx[end];
        delta_ctx.* = Template.Context.init(ctx.alloc);
        const builder = d.builder();
        try builder.build(delta_ctx);
        try delta_ctx.put("index", try std.fmt.allocPrint(ctx.alloc, "0x{X}", .{d.index}));
        try delta_ctx.put("title_uri", try std.fmt.allocPrint(ctx.alloc, "{X}", .{d.index}));
        if (d.getComments(ctx.alloc)) |cmts| {
            try delta_ctx.put(
                "comments_icon",
                try std.fmt.allocPrint(ctx.alloc, "<span class=\"icon\">\xee\xa0\x9c {}</span>", .{cmts.len}),
            );
        } else |_| unreachable;
        end += 1;
        continue;
        //dom.pushSlice(diffRow(ctx.alloc, d) catch continue);
    }
    var tmpl = Template.find("deltalist.html");
    tmpl.init(ctx.alloc);
    //_ = try tmpl.addElements(ctx.alloc, "list", tmpl_ctx[0..end]);
    try tmpl.ctx.?.putBlock("list", tmpl_ctx[0..end]);
    ctx.sendTemplate(&tmpl) catch return error.Unknown;
}
