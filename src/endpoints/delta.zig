pub const AddCommentReq = struct {
    comment: []const u8,
    did: []const u8,
    diff_id: []const u8,
    close: ?bool = false,
    submit: ?bool = false,
    reopen: ?bool = false,
    lock: ?bool = false,
    unlock: ?bool = false,
};

pub fn addComment(
    comptime location: []const u8,
    repo: []const u8,
    id: usize,
    valid: AddCommentReq,
    f: *Frame,
) RouterError!?Message {
    var delta = Delta.open(repo, id, f.alloc, f.io) catch return error.ServerFault;
    delta.thread.load(f.alloc, f.io) catch return error.ServerFault;
    defer delta.commit(f.io) catch log.err("unable to commit delta", .{});

    const user = if (f.user) |usr| usr.username.? else "public";
    var msg: ?Message = null;
    if (valid.reopen.?) {
        msg = delta.setOpen(
            .{ .author = user, .message = valid.comment },
            f.alloc,
            f.io,
        ) catch |e| switch (e) {
            error.NoMessage => null,
            else => return error.ServerFault,
        };
    } else if (valid.close.?) {
        msg = delta.setClosed(
            .{ .author = user, .message = valid.comment },
            f.alloc,
            f.io,
        ) catch |e| switch (e) {
            error.NoMessage => null,
            else => return error.ServerFault,
        };
    } else {
        msg = delta.thread.addComment(
            user,
            valid.comment,
            f.alloc,
            f.io,
        ) catch return error.ServerFault;
    }
    var buf: [2048]u8 = undefined;
    const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/" ++ location ++ "/{x}", .{ repo, id });
    try events.newComment(repo, id, loc, msg orelse .empty, f.io);
    f.redirect(loc, .see_other) catch unreachable;
    return msg;
}

pub fn incrView(d: *Delta, f: *Frame) !void {
    const ua = f.request.user_agent orelse return;
    switch (ua.agent) {
        .script, .bot, .unknown => return,
        .browser => {},
    }

    const username: []const u8 = if (f.user) |usr|
        (usr.username orelse "[null]")
    else
        f.request.remote_addr;

    d.viewers.view(username, f.alloc, f.io) catch |err| {
        log.err("unable to add view on delta {} {} '{s}' [{any}]", .{
            d.index, err, username, d.viewers,
        });
    };
    d.commit(f.io) catch {};
}

pub fn deltaResult(d: *const Delta, a: Allocator) !S.SearchFlavor.Delta {
    const msg = d.message[0..@min(
        d.message.len,
        findPos(u8, d.message, 256, " ") orelse d.message.len,
        find(u8, d.message, "```") orelse d.message.len,
    )];

    // TODO injectable if d.repo is unsanitized
    const uri = switch (d.attach) {
        .issue => try a.print("/repo/{s}/issue", .{d.repo}),
        .diff => try a.print("/repo/{s}/diff", .{d.repo}),
        .remote => try a.print("/repo/{s}/issue", .{d.repo}),
        else => try a.print("/repo/{s}/issue", .{d.repo}),
    };

    const flavor: []const u8 = switch (d.attach) {
        .diff => "diff",
        .issue, .remote => "issue",
        else => "ukn",
    };

    // TODO implement seen
    return .{
        .index = .safe(try a.print("{x}", .{d.index})),
        .flavor = .safe(flavor),
        .uri_base = .abx(uri),
        .title = .abx(if (d.title.len == 0) "[No Title]" else d.title),
        .comment_count = d.thread.count,
        .view_count = d.viewers.count,
        .style = if (d.state.isOpen()) .safe("") else .safe("closed"),
        .desc = .safe(if (msg.len == 0) "&nbsp;" else try a.print("{f}", .{abx.Html{ .text = msg }})),
        .delta_meta = switch (d.attach) {
            .issue => .{ .repo = .abx(d.repo) },
            .diff => .{ .repo = .abx(d.repo) },
            .remote => .{ .repo = .abx(d.repo) },
            else => null,
        },
        // TODO comment liveness
        .comment = .safe(svg.Icon.slice(if (false) .comment else .comment_new, .{})),
        .viewers = .safe(svg.Icon.slice(.eye, .{})),
    };
}

const MsgData = struct {
    ?[]const u8, // system tag
    []const u8, // comment body
};

/// TODO prove safe
fn decodeMessage(
    msg: Message,
    repo: *const Repo,
    diffs: []const Patch.Diff,
    rev: ?usize,
    a: Allocator,
    io: Io,
) !MsgData {
    var systag: ?[]const u8 = null;
    var comment_body: []const u8 = "";
    if (diffs.len == 0) {
        var w: Io.Writer.Allocating = .init(a);
        const writer = &w.writer;
        _ = diffs_ep.translateComment(msg.message, &.{}, repo, writer, a, io) catch
            return error.ServerFault;
        comment_body = try w.toOwnedSlice();
        //comment_body = try (a, "{f}", .{abx.Html{
        //    .text = msg.message orelse "[Empty Message]",
        //}});
        return .{ systag, comment_body };
    }

    var comment_diffs: []const Patch.Diff = diffs;

    const comment_rev: enum { older, current, newer } = if (rev) |r| if (msg.extra0 < r)
        .older
    else if (msg.extra0 > r)
        .newer
    else
        .current else .current;

    systag = switch (comment_rev) {
        .older => "<div class=\"sysmsg\">Comment on previous revision.</div>\n",
        .newer => "<div class=\"sysmsg green\">Comment on newer revision.</div>\n",
        .current => null,
    };
    switch (comment_rev) {
        .older, .newer => {
            const comment_diff = Diff.open(msg.extra0, a, io) catch return error.ServerFault;
            const comment_patch: Patch = .init(comment_diff.patch.bytes);
            comment_diffs = comment_patch.parse(a) catch {
                return .{
                    "<div class=\"sysmsg red\">Unable to parse invalid patch.</div>\n",
                    try a.print("{f}", .{abx.Html{ .text = if (msg.message.len > 0)
                        msg.message
                    else
                        "[Empty Message]" }}),
                };
            };
        },
        .current => {},
    }
    var w: Io.Writer.Allocating = .init(a);
    const writer = &w.writer;
    const found = diffs_ep.translateComment(msg.message, comment_diffs, repo, writer, a, io) catch
        return error.ServerFault;
    if (!found) systag = null;
    comment_body = try w.toOwnedSlice();
    return .{ systag, comment_body };
}

const Messages = S.CommentThreadHtml.Messages;
pub fn genThreadMessages(
    delta: *Delta,
    repo: *const Repo,
    patch: ?*const Patch,
    btns: struct { edit: bool = false },
    a: Allocator,
    io: Io,
) ![]Messages {
    const now: i64 = Io.Clock.real.now(io).toSeconds();
    delta.thread.load(a, io) catch |err| {
        log.err("Unable to load comments for thread {} {}", .{ delta.index, err });
        return error.ServerFault;
    };
    if (delta.thread.messages.items.len == 0) return &.{};
    const messages = try a.alloc(S.CommentThreadHtml.Messages, delta.thread.messages.items.len);
    for (delta.thread.messages.items, messages) |msg, *html| {
        const date = try a.print("{f}", .{Humanize.unix(msg.updated, now)});
        const msg_hash = try a.print("{x}", .{msg.hash[0..10]});
        const diffs: []const Patch.Diff = if (patch) |p| try p.parse(a) else &.{};
        const rev: ?usize = if (patch) |p| p.revision else null;
        const systag, const body = try decodeMessage(msg, repo, diffs, rev, a, io);
        html.* = switch (msg.kind) {
            .comment => .{
                .author = .abx(try a.dupe(u8, if (msg.author.len > 0) msg.author else "[no author]")),
                .date = .safe(date),
                .system_tag = if (systag) |st| .safe(st) else null,
                .message = .safe(body),
                .edit = if (btns.edit) .{ .index = delta.index, .hash = .safe(msg_hash) } else null,
                .direct_reply = null, // .{ .index = delta.index, .hash = .safe(msg_hash) },
                .sub_thread = null,
            },
            .diff_update => .{
                .author = .abx(try a.dupe(u8, if (msg.author.len > 0) msg.author else "[no author]")),
                .date = .safe(date),
                .message = .abx(msg.message),
                .edit = null,
                .direct_reply = null,
                .sub_thread = null,
            },
            .state_change => .{
                .class = .safe("system"),
                .author = .abx(try a.dupe(u8, if (msg.author.len > 0) msg.author else "[no author]")),
                .date = .safe(date),
                .message = .abx(msg.message),
                .edit = null,
                .direct_reply = null,
                .sub_thread = null,
            },
        };
    }
    return messages;
}

pub fn status(d: *const Delta) []const u8 {
    return if (d.state.closed)
        "<span class=closed>closed</span>"
    else if (d.state.locked)
        "<span class=locked>locked</span>"
    else if (d.state.draft)
        "<span class=draft>draft</span>"
    else
        "<span class=open>open</span>";
}

pub fn actionButtons(f: *Frame, delta: *const Delta) [2][]const u8 {
    var buttons: [2][]const u8 = undefined;
    if (f.user != null) {
        buttons[0] = if (delta.state.locked)
            "<button type=submit name=unlock value=t>Unlock</button>\n"
        else
            "<button type=submit name=lock value=t>Lock</button>\n";
    } else buttons[0] = &.{};

    buttons[1] = if (delta.state.closed)
        "<button type=submit name=reopen value=t>Reopen</button>\n"
    else
        "<button type=submit name=close value=t>Close</button>\n";

    return buttons;
}

const Repos = @import("repos.zig");
const searchEP = @import("search.zig");
const Types = @import("../types.zig");
const Search = @import("../Search.zig");
const Delta = Types.Delta;
const Message = Types.Message;
const Diff = Types.Diff;
const CommentsMeta = Delta.CommentsMeta;
const Humanize = @import("../humanize.zig");
const Repo = @import("../git.zig").Repo;
const Patch = @import("../Patch.zig");
const events = @import("../events.zig");
const RouteData = Repos.RouteData;
const svg = @import("../svg.zig");

const diffs_ep = @import("repos/diffs.zig");

const verse = @import("verse");
const abx = verse.Antibiotic;
const Frame = verse.Frame;
const RouterError = verse.Router.Error;
const T = verse.template;
const S = T.Structs;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;
const log = std.log.scoped(.srctree_delta);
const bufPrint = std.fmt.bufPrint;
const findPos = std.mem.findPos;
const find = std.mem.find;
