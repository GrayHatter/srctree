pub const Event = union(enum) {
    repo: Repo,
    build: Build,
    comment: Comment,

    pub const Repo = enum {
        push,
        force_push,
    };

    pub const Build = enum {
        start,
        finish,
    };

    pub const Comment = enum {
        new,
        new_system,
    };

    pub fn trigger(evt: Event, repo: []const u8, idx: usize, url: []const u8, msg: Message, io: Io) void {
        switch (evt) {
            .repo => unreachable,
            .build => unreachable,
            .comment => |cmt| switch (cmt) {
                .new, .new_system => {
                    Ack.email.newComment(repo, idx, url, msg, io) catch {};
                },
            },
        }
    }
};

pub fn newComment(repo: []const u8, idx: usize, url: []const u8, msg: Message, io: Io) !void {
    if (comptime builtin.is_test) return;
    const evt: Event = .{ .comment = .new };
    evt.trigger(repo, idx, url, msg, io);
}

pub const Ack = struct {
    pub const email = struct {
        pub fn send(
            sender: []const u8,
            receiver: []const u8,
            date: []const u8,
            subject: []const u8,
            body: []const u8,
            io: Io,
        ) void {
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

        pub fn newComment(repo: []const u8, idx: usize, url: []const u8, msg: Message, io: Io) !void {
            const notifications = @import("Config.zig").global.notifications orelse return;
            if (!notifications.enabled) return;
            const sender = if (cfg.notifications) |note|
                note.sender orelse "\"srctree\" <srctree@gr.ht>"
            else
                "\"srctree\" <srctree@gr.ht>";

            const receiver = if (cfg.notifications) |note|
                note.receiver orelse "\"srctree\" <srcadmin@gr.ht>"
            else
                "\"srctree\" <srcadmin@gr.ht>";

            const date = "Sun, 26 Apr 2026 09:24:31 2026 -0700";

            var sub_b: [2048]u8 = undefined;
            const subject = try bufPrint(&sub_b, "New Comment on #{} in {s} from {s}", .{
                idx, repo, msg.author orelse "[no author given]",
            });
            var body_b: [2048]u8 = undefined;
            const body = try bufPrint(&body_b, "https://srctree.gr.ht{s}", .{url});

            send(sender, receiver, date, subject, body, io);
        }
    };
};

const std = @import("std");
const builtin = @import("builtin");
const cfg = &@import("Config.zig").global;

const Io = std.Io;
const smtp = @import("smtp");
const Message = @import("types.zig").Message;
const bufPrint = std.fmt.bufPrint;
