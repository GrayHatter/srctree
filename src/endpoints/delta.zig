const DeltaListHtml = T.PageData("delta-list.html");
const DeltaList = S.DeltaListHtml.DeltaList;
const DeltaMeta = S.DeltaListHtml.DeltaList.DeltaMeta;

pub const AddCommentReq = struct {
    comment: []const u8,
    did: []const u8,
    diff_id: []const u8,
    close: ?bool = false,
    submit: ?bool = false,
    repoen: ?bool = false,
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
    var delta = Delta.open(repo, id, f.alloc, f.io) catch
        return error.Unknown;

    const user = if (f.user) |usr| usr.username.? else "public";
    var msg: ?Message = null;
    if (valid.close.?) {
        msg = delta.setClosed(
            .{ .author = user, .message = valid.comment },
            f.alloc,
            f.io,
        ) catch return error.ServerFault;
    } else {
        msg = delta.addComment(
            .{ .author = user, .message = valid.comment },
            f.alloc,
            f.io,
        ) catch return error.ServerFault;
    }
    var buf: [2048]u8 = undefined;
    const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/" ++ location ++ "/{x}", .{ repo, id });
    f.redirect(loc, .see_other) catch unreachable;
    return msg;
}

pub fn deltaList(d: Delta, comments: CommentsMeta, a: Allocator) !S.DeltaListHtml.DeltaList {
    const msg = d.message[0..@min(
        d.message.len,
        findPos(u8, d.message, 256, " ") orelse d.message.len,
        find(u8, d.message, "```") orelse d.message.len,
    )];

    // TODO injectable if d.repo is unsanitized
    const uri = switch (d.attach) {
        .issue => try allocPrint(a, "/repo/{s}/issue", .{d.repo}),
        .diff => try allocPrint(a, "/repo/{s}/diff", .{d.repo}),
        .remote => try allocPrint(a, "/repo/{s}/issue", .{d.repo}),
        else => try allocPrint(a, "/repo/{s}/issue", .{d.repo}),
    };

    const meta: ?DeltaMeta = switch (d.attach) {
        .issue => .{ .repo = d.repo, .flavor = "issue" },
        .diff => .{ .repo = d.repo, .flavor = "diff" },
        .remote => rmt: {
            break :rmt .{ .repo = d.repo, .flavor = try allocPrint(a, "Tracking remote issue from {f}", .{
                abx.Html{ .text = d.attach_remote },
            }) };
        },
        else => null,
    };

    // TODO implement seen
    return .{
        .index = try allocPrint(a, "{x}", .{d.index}),
        .uri_base = uri,
        .title = try allocPrint(a, "{f}", .{
            abx.Html{ .text = if (d.title.len == 0) "[No Title]" else d.title },
        }),
        .comment_new = if (comments.new) " new" else "",
        .comment_count = comments.count,
        .desc = if (msg.len == 0) "&nbsp;" else try allocPrint(a, "{f}", .{abx.Html{ .text = msg }}),
        .delta_meta = meta,
    };
}

pub fn list(f: *Frame, Itr: type, itr: *search.Iterator(Itr, Delta), search_str: []const u8) RouterError!void {
    var d_list: ArrayList(DeltaList) = .{};
    while (itr.next(f.alloc, f.io)) |deltaC| {
        var d = deltaC;
        if (d.state.embargoed) continue;

        _ = d.loadThread(f.alloc, f.io) catch return error.ServerFault;
        const cmtsmeta = d.countComments(f.io);
        try d_list.append(f.alloc, try deltaList(d, cmtsmeta, f.alloc));
    }

    var og_title_b: [256]u8 = undefined;
    const meta_head = S.MetaHeadHtml{ .open_graph = .{
        .title = bufPrint(&og_title_b, "{} open issues", .{d_list.items.len}) catch unreachable,
    } };

    var page = DeltaListHtml.init(.{
        .meta_head = meta_head,
        .body_header = f.response_data.get(S.BodyHeaderHtml).?.*,
        //.search_action = uri_base,
        .delta_list = try d_list.toOwnedSlice(f.alloc),
        .search = search_str,
    });

    try f.sendPage(&page);
}

const MsgData = struct {
    ?[]const u8, // system tag
    []const u8, // comment body
};

fn decodeMessage(msg: Message, repo: *const Repo, patch: ?*const Patch, a: Allocator, io: Io) !MsgData {
    var systag: ?[]const u8 = null;
    var comment_body: []const u8 = "";
    if (patch) |p| {
        var comment_diff: Diff = undefined;
        var comment_patch = p.*;

        const comment_rev: enum { older, current, newer } = if (p.revision) |r| if (msg.extra0 < r)
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
                comment_diff = (Diff.open(msg.extra0, a, io) catch
                    return error.ServerFault) orelse return error.ServerFault;
                comment_patch = .init(comment_diff.patch.blob);
                comment_patch.parse(a) catch {
                    return .{
                        "<div class=\"sysmsg red\">Unable to parse invalid patch.</div>\n",
                        try allocPrint(a, "{f}", .{abx.Html{ .text = msg.message orelse "[Empty Message]" }}),
                    };
                };
            },
            .current => {},
        }
        const found, comment_body = diffs_ep.translateComment(msg.message.?, comment_patch, repo, a, io) catch
            return error.ServerFault;
        if (!found) systag = null;
    } else {
        comment_body = try allocPrint(a, "{f}", .{abx.Html{ .text = msg.message orelse "[Empty Message]" }});
    }
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
    var thread = delta.loadThread(a, io) catch |err| {
        log.err("Unable to load comments for thread {} {}", .{ delta.index, err });
        return error.ServerFault;
    };
    if (thread.messages.items.len == 0) return &.{};
    const messages = try a.alloc(S.CommentThreadHtml.Messages, thread.messages.items.len);
    for (thread.messages.items, messages) |msg, *html| {
        const author = if (msg.author) |athr| try allocPrint(a, "{f}", .{abx.Html{ .text = athr }}) else "";
        const date = try allocPrint(a, "{f}", .{Humanize.unix(msg.updated, now)});
        const msg_hash = try allocPrint(a, "{x}", .{msg.hash[0..10]});
        const systag, const body = try decodeMessage(msg, repo, patch, a, io);
        html.* = switch (msg.kind) {
            .comment => .{
                .author = author,
                .date = date,
                .system_tag = systag,
                .message = body,
                .edit = if (btns.edit) .{ .index = delta.index, .hash = msg_hash } else null,
                .direct_reply = .{ .index = delta.index, .hash = msg_hash },
                .sub_thread = null,
            },
            .diff_update => .{
                .author = author,
                .date = date,
                .message = msg.message.?,
                .edit = null,
                .direct_reply = null,
                .sub_thread = null,
            },
            .state_change => .{
                .class = "system",
                .author = author,
                .date = date,
                .message = msg.message.?,
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
const Types = @import("../types.zig");
const search = Types.search;
const Delta = Types.Delta;
const Message = Types.Message;
const Diff = Types.Diff;
const CommentsMeta = Delta.CommentsMeta;
const Humanize = @import("../humanize.zig");
const Repo = @import("../git.zig").Repo;
const Patch = @import("../patch.zig");

const diffs_ep = @import("repos/diffs.zig");

const verse = @import("verse");
const abx = verse.abx;
const Frame = verse.Frame;
const RouterError = verse.Router.Error;
const T = verse.template;
const S = T.Structs;

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArrayList = std.ArrayList;
const log = std.log.scoped(.srctree_delta);
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const findPos = std.mem.findPos;
const find = std.mem.find;
