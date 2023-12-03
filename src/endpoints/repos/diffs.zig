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
const diffLine = @import("commits.zig").diffLine;

const GET = Endpoint.Router.Methods.GET;
const POST = Endpoint.Router.Methods.POST;

const CURL = @import("../../curl.zig");
const Bleach = @import("../../bleach.zig");
const Diffs = Endpoint.Types.Diffs;
const Comments = Endpoint.Types.Comments;
const Comment = Comments.Comment;

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

fn diffValidForRepo(repo: []const u8, diff: usize) bool {
    _ = repo;
    return diff > 0;
}

pub fn router(ctx: *Context) Error!Endpoint.Endpoint {
    std.debug.assert(std.mem.eql(u8, "diffs", ctx.uri.next().?));
    const verb = ctx.uri.peek() orelse return Endpoint.Router.router(ctx, &routes);

    const repo_name = "none";
    if (isHex(verb)) |dnum| {
        if (diffValidForRepo(repo_name, dnum))
            return view;
    }

    return Endpoint.Router.router(ctx, &routes);
}

fn new(r: *Response, _: *UriIter) Error!void {
    const a = r.alloc;
    var tmpl = Template.find("diffs.html");
    tmpl.init(r.alloc);

    var dom = DOM.new(r.alloc);
    dom = dom.open(HTML.element("intro", null, null));
    dom.push(HTML.text("New Pull Request"));
    dom = dom.close();
    var fattr = try r.alloc.dupe(HTML.Attr, &[_]HTML.Attr{
        .{ .key = "action", .value = "new" },
        .{ .key = "method", .value = "POST" },
    });
    dom = dom.open(HTML.form(null, fattr));

    dom.push(try HTML.inputAlloc(a, "diff source", .{ .placeholder = "Patch URL" }));
    dom.push(try HTML.inputAlloc(a, "title", .{ .placeholder = "Diff Title" }));
    dom.push(try HTML.textareaAlloc(a, "desc", .{ .placeholder = "Additional information about this patch suggestion" }));
    dom.dupe(HTML.btnDupe("Submit", "submit"));
    dom.dupe(HTML.btnDupe("Preview", "preview"));
    dom = dom.close();

    _ = try tmpl.addElements(r.alloc, "diff", dom.done());
    r.sendTemplate(&tmpl) catch unreachable;
}

fn inNetwork(str: []const u8) bool {
    if (!std.mem.startsWith(u8, str, "https://srctree.gr.ht")) return false;
    for (str) |c| if (c == '@') return false;
    return true;
}

fn fetch(a: Allocator, uri: []const u8) ![]const u8 {
    var client = std.http.Client{
        .allocator = a,
    };
    defer client.deinit();

    var request = client.fetch(a, .{
        .location = .{ .url = uri },
    });
    if (request) |*req| {
        defer req.deinit();
        std.debug.print("request code {}\n", .{req.status});
        if (req.body) |b| {
            std.debug.print("request body {s}\n", .{b});
            return a.dupe(u8, b);
        }
    } else |err| {
        std.debug.print("stdlib request failed with error {}\n", .{err});
    }

    var curl = try CURL.curlRequest(a, uri);
    if (curl.code != 200) return error.UnexpectedResponseCode;

    if (curl.body) |b| return b;
    return error.EpmtyReponse;
}

fn newPost(r: *Response, uri: *UriIter) Error!void {
    const rd = Repo.RouteData.make(uri) orelse return error.Unrouteable;
    if (r.usr_data) |usrdata| if (usrdata.post_data) |post| {
        var valid = post.validator();
        const src = try valid.require("diff source");
        const title = try valid.require("title");
        const desc = try valid.require("desc");
        const action = valid.optional("submit") orelse valid.optional("preview") orelse return error.BadData;
        var diff = Diffs.new(rd.name, title.value, src.value, desc.value) catch unreachable;
        diff.writeOut() catch unreachable;
        if (inNetwork(src.value)) {
            std.debug.print("src {s}\ntitle {s}\ndesc {s}\naction {s}\n", .{
                src.value,
                title.value,
                desc.value,
                action.name,
            });
            var data = fetch(r.alloc, src.value) catch unreachable;
            var filename = std.fmt.allocPrint(
                r.alloc,
                "data/patch/{s}.{x}.patch",
                .{ rd.name, diff.index },
            ) catch unreachable;
            var file = std.fs.cwd().createFile(filename, .{}) catch unreachable;
            defer file.close();
            file.writer().writeAll(data) catch unreachable;
        }
    };

    var tmpl = Template.find("diffs.html");
    tmpl.init(r.alloc);
    try tmpl.addVar("diff", "new data attempting");
    r.sendTemplate(&tmpl) catch unreachable;
}

fn newComment(r: *Response, uri: *UriIter) Error!void {
    const rd = Repo.RouteData.make(uri) orelse return error.Unrouteable;
    if (r.usr_data) |usrdata| if (usrdata.post_data) |post| {
        var valid = post.validator();
        const diff_id = try valid.require("diff-id");
        const msg = try valid.require("comment");
        const diff_index = isHex(diff_id.value) orelse return error.Unrouteable;

        var diff = Diffs.open(r.alloc, diff_index) catch unreachable orelse return error.Unrouteable;
        var c = Comments.new("name", msg.value) catch unreachable;

        diff.addComment(r.alloc, c) catch {};
        diff.writeOut() catch unreachable;
        var buf: [2048]u8 = undefined;
        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/diffs/{x}", .{ rd.name, diff_index });
        r.redirect(loc, true) catch unreachable;
        return;
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

fn view(r: *Response, uri: *UriIter) Error!void {
    const rd = Repo.RouteData.make(uri) orelse return error.Unrouteable;
    const diff_target = uri.next().?;
    const index = isHex(diff_target) orelse return error.Unrouteable;

    var tmpl = Template.find("diff-review.html");
    tmpl.init(r.alloc);

    var dom = DOM.new(r.alloc);

    var diff = (Diffs.open(r.alloc, index) catch return error.Unrouteable) orelse return error.Unrouteable;
    dom = dom.open(HTML.element("context", null, null));
    dom.push(HTML.text(rd.name));
    dom = dom.open(HTML.p(null, null));
    dom.push(HTML.text(Bleach.sanitizeAlloc(r.alloc, diff.title, .{}) catch unreachable));
    dom = dom.close();
    dom = dom.open(HTML.p(null, null));
    dom.push(HTML.text(Bleach.sanitizeAlloc(r.alloc, diff.desc, .{}) catch unreachable));
    dom = dom.close();
    dom = dom.close();

    _ = try tmpl.addElements(r.alloc, "patch_header", dom.done());

    var comments = DOM.new(r.alloc);
    for ([_]Comment{ .{
        .author = "grayhatter",
        .message = "Wow, srctree's Diff view looks really good!",
    }, .{
        .author = "robinli",
        .message = "I know, it's clearly the best I've even seen. Soon it'll even look good in Hastur!",
    } }) |cm| {
        comments.pushSlice(addComment(r.alloc, cm) catch unreachable);
    }
    for (diff.getComments(r.alloc) catch unreachable) |cm| {
        comments.pushSlice(addComment(r.alloc, cm) catch unreachable);
    }

    _ = try tmpl.addElements(r.alloc, "comments", comments.done());

    const hidden = [_]HTML.Attr{
        .{ .key = "type", .value = "hidden" },
        .{ .key = "name", .value = "diff-id" },
        .{ .key = "value", .value = diff_target },
    };

    const form_data = [_]HTML.E{
        HTML.input(&hidden),
    };

    _ = try tmpl.addElements(r.alloc, "form-data", &form_data);

    const filename = try std.fmt.allocPrint(r.alloc, "data/patch/{s}.{x}.patch", .{ rd.name, diff.index });
    std.debug.print("{s}\n", .{filename});
    var file: ?std.fs.File = std.fs.cwd().openFile(filename, .{}) catch null;
    if (file) |f| {
        const fdata = f.readToEndAlloc(r.alloc, 0xFFFFF) catch return error.Unknown;
        var patch = DOM.new(r.alloc);
        patch = patch.open(HTML.element("patch", null, null));
        patch.pushSlice(diffLine(r.alloc, fdata));
        patch = patch.close();
        _ = try tmpl.addElementsFmt(r.alloc, "{pretty}", "patch", patch.done());
        f.close();
    } else try tmpl.addString("patch", "Patch not found");

    r.sendTemplate(&tmpl) catch unreachable;
}

fn diffRow(a: Allocator, diff: Diffs.Diff) ![]HTML.Element {
    var dom = DOM.new(a);

    dom = dom.open(HTML.element("diff", null, null));
    const title = try Bleach.sanitizeAlloc(a, diff.title, .{ .rules = .title });
    const desc = try Bleach.sanitizeAlloc(a, diff.desc, .{});
    const href = try std.fmt.allocPrint(a, "{x}", .{diff.index});

    dom.push(try HTML.aHrefAlloc(a, title, href));
    dom.dupe(HTML.element("desc", desc, &HTML.Attr.class("muted")));
    dom = dom.close();

    return dom.done();
}

fn list(r: *Response, uri: *UriIter) Error!void {
    const rd = Repo.RouteData.make(uri) orelse return error.Unrouteable;
    var dom = DOM.new(r.alloc);
    dom.push(HTML.element("search", null, null));
    dom = dom.open(HTML.element("actionable", null, null));

    for (0..Diffs.last() + 1) |i| {
        var d = Diffs.open(r.alloc, i) catch continue orelse continue;
        defer d.raze(r.alloc);
        if (!std.mem.eql(u8, d.repo, rd.name)) continue;
        dom.pushSlice(diffRow(r.alloc, d) catch continue);
    }
    dom = dom.close();
    const diffs = dom.done();
    var tmpl = Template.find("diffs.html");
    tmpl.init(r.alloc);
    _ = try tmpl.addElements(r.alloc, "diff", diffs);
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;
    r.start() catch return Error.Unknown;
    r.send(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}
