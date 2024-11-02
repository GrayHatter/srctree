const std = @import("std");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;

fn usage() !void {
    std.debug.print("TODO write usage/help text\n", .{});
}

pub const Server = struct {
    host: []const u8,
    port: u16,

    stream: ?std.net.Stream = null,

    pub fn connect(srv: *Server, a: Allocator) !void {
        std.debug.assert(srv.stream == null);
        srv.stream = try std.net.tcpConnectToHost(a, srv.host, srv.port);
    }

    fn sendBody(srv: *Server, msg: Message) !void {
        const stream = srv.stream orelse return error.StreamInvalid;
        var buffer: [0xffff]u8 = undefined;
        const format: []const u8 =
            \\From: {s}
            \\To: {s}
            \\Subject: {s}
            \\
            \\{s}
            \\
        ;
        const data = try std.fmt.bufPrint(&buffer, format, .{
            msg.from,
            msg.to.?,
            msg.subject,
            msg.body,
        });
        try stream.writeAll(data);
        try stream.writeAll("\r\n.\r\n");
    }

    pub fn deliver(srv: *Server, msg: Message) !bool {
        const stream = srv.stream orelse return error.StreamInvalid;
        defer stream.close();
        defer srv.stream = null;

        var buffer: [0xFFFF]u8 = undefined;
        var answer = buffer[0..try stream.read(&buffer)];
        if (!startsWith(u8, answer, "220 ")) return error.UnexpectedMessage;

        try stream.writeAll("HELO 98.42.94.105\r\n");
        answer = buffer[0..try stream.read(&buffer)];
        if (!startsWith(u8, answer, "250 ")) {
            std.debug.print("answer: {s}\n", .{answer});
            return error.UnexpectedMessage;
        }

        try stream.writeAll("MAIL FROM:");
        try stream.writeAll(msg.from);
        try stream.writeAll("\r\n");
        answer = buffer[0..try stream.read(&buffer)];
        std.debug.print("answer: {s}\n", .{answer});
        if (!startsWith(u8, answer, "250 ")) {
            return error.UnexpectedMessage;
        }

        try stream.writeAll("RCPT TO:");
        try stream.writeAll(msg.to.?);
        try stream.writeAll("\r\n");
        answer = buffer[0..try stream.read(&buffer)];
        std.debug.print("answer: {s}\n", .{answer});
        if (!startsWith(u8, answer, "250 ")) {
            return error.UnexpectedMessage;
        }

        try stream.writeAll("DATA\r\n");
        answer = buffer[0..try stream.read(&buffer)];
        std.debug.print("answer: {s}\n", .{answer});
        if (!startsWith(u8, answer, "354 ")) {
            return error.UnexpectedMessage;
        }
        try srv.sendBody(msg);
        answer = buffer[0..try stream.read(&buffer)];
        std.debug.print("answer: {s}\n", .{answer});
        if (!startsWith(u8, answer, "250 ")) {
            return error.UnexpectedMessage;
        }

        try stream.writeAll("QUIT\r\n");
        answer = buffer[0..try stream.read(&buffer)];
        std.debug.print("answer: {s}\n", .{answer});
        if (!startsWith(u8, answer, "221 ")) {
            return error.UnexpectedMessage;
        }

        return false;
    }
};

pub const Address = []const u8;
pub const Subject = []const u8;
pub const Body = []const u8;

pub const Message = struct {
    from: Address,
    subject: Subject,
    body: Body,
    to: ?Address,
};

pub fn send(a: Allocator, srv: *Server, msg: Message) !void {
    try srv.connect(a);
    _ = try srv.deliver(msg);
}

fn receive() !void {
    var stdin = std.io.getStdIn();
    const in_reader = stdin.reader();
    const reader = in_reader.any();
    const a = std.heap.page_allocator;
    const message = reader.readAllAlloc(a, 0xA00000) catch |err| {
        switch (err) {
            else => std.log.err("something went wrong {}", .{err}),
        }
        std.process.exit(2);
    };
    _ = message;
}

pub fn main() !void {
    var args = std.process.args();
    var config_filename: []const u8 = "./mailer.ini";
    _ = args.next() orelse {
        std.log.err("argv is invalid", .{});
        std.process.exit(10);
    };
    const action = args.next() orelse {
        std.log.err("no action was supplied", .{});
        std.process.exit(11);
    };
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-h")) {
            // TODO stdout instead
            try usage();
            std.process.exit(0);
        } else if (std.mem.startsWith(u8, arg, "-c")) {
            if (args.next()) |arg_conf| {
                config_filename = arg_conf;
            } else {
                std.log.err("no config file given following -c", .{});
                std.process.exit(1);
            }
        }
    }

    const a = std.heap.page_allocator;
    if (std.mem.eql(u8, action, "send")) {
        std.log.err("send not implemented", .{});
        var server: Server = .{
            .host = "mail.gr.ht",
            .port = 587,
        };

        send(a, &server, .{
            .from = "<mailer@gr.ht>",
            .subject = "This is a test email",
            .body = "",
            .to = "<someuser@srctree.gr.ht>",
        }) catch std.process.exit(1);
        return;
    } else if (std.mem.eql(u8, action, "receive")) {
        std.log.err("receive not implemented (but good luck!)", .{});
        try receive();
        std.process.exit(1);
    } else if (std.mem.eql(u8, action, "-h")) {
        try usage();
        std.process.exit(0);
    }
}
