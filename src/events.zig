pub const Event = enum {
    repo_push,
    new_comment,
    new_comment_system,
};

pub fn newComment(repo: []const u8, idx: usize, url: []const u8, msg: Message, io: Io) !void {
    if (comptime builtin.is_test) return;
    const notifications = root.global_config.notifications orelse return;
    if (!notifications.enabled) return;

    inline for (@typeInfo(Ack.email).@"struct".decls) |dcl| {
        if (std.mem.eql(u8, dcl.name, "newComment"))
            try @call(.auto, @field(Ack.email, dcl.name), .{ repo, idx, url, msg, io });
    }
}

pub const Ack = struct {
    pub const email = struct {
        pub fn newComment(repo: []const u8, idx: usize, url: []const u8, msg: Message, io: Io) !void {
            const sender = if (root.global_config.notifications) |note|
                note.sender orelse "\"srctree\" <srctree@gr.ht>"
            else
                "\"srctree\" <srctree@gr.ht>";

            const receiver = if (root.global_config.notifications) |note|
                note.receiver orelse "\"srctree\" <srcadmin@gr.ht>"
            else
                "\"srctree\" <srcadmin@gr.ht>";

            const date = "Sun, 26 Apr 2026 09:24:31 2026 -0700";

            var sub_b: [2048]u8 = undefined;
            const subject = try bufPrint(&sub_b, "New Comment on #{} in {s} from {s}", .{
                idx, repo, msg.author.?,
            });
            var body_b: [2048]u8 = undefined;
            const body = try bufPrint(&body_b, "https://srctree.gr.ht{s}", .{url});

            smtp.sendMsg(.{
                .from = sender,
                .to = receiver,
                .date = date,
                .subject = subject,
                .body = body,
            }, io) catch |e| {
                std.log.err("{any}", .{e});
                @panic("backtrace");
            };
        }
    };
};

const std = @import("std");
const root = @import("root");
const builtin = @import("builtin");

const Io = std.Io;
const smtp = @import("smtp");
const Message = @import("types.zig").Message;
const bufPrint = std.fmt.bufPrint;
