pub const Client = struct {
    host: []const u8,
    addr: net.IpAddress,
    stream: net.Stream,

    reader: net.Stream.Reader,
    read_bytes: [tls.Client.min_buffer_len * 4]u8 = undefined,
    writer: net.Stream.Writer,
    write_bytes: [tls.Client.min_buffer_len * 4]u8 = undefined,
    tls: ?Tls = null,
    tls_buffer: [tls.Client.min_buffer_len * 2]u8 = undefined,

    pub const Answer = struct {
        continues: bool,
        code: Code,
        bytes: []const u8,
    };

    pub const Tls = struct {
        reader: *Io.Reader,
        writer: *Io.Writer,
        client: std.crypto.tls.Client,

        pub const Config = struct {
            host: []const u8,
            entropy: *const [tls.Client.Options.entropy_len]u8,
            w_b: *[tls.Client.min_buffer_len]u8,
            r_b: *[tls.Client.min_buffer_len]u8,
            now: Io.Timestamp,
        };

        pub fn init(r: *Io.Reader, w: *Io.Writer, cfg: Config) !Tls {
            return .{
                .reader = r,
                .writer = w,
                .client = try .init(r, w, .{
                    .host = .{ .explicit = cfg.host },
                    .ca = .no_verification,
                    .write_buffer = cfg.w_b,
                    .read_buffer = cfg.r_b,
                    .entropy = cfg.entropy,
                    .realtime_now = cfg.now,
                }),
            };
        }
    };

    pub fn init(host: []const u8, addr: net.IpAddress, io: Io) !Client {
        return .{
            .host = host,
            .addr = addr,
            .stream = try addr.connect(io, .{ .mode = .stream }),
            .reader = undefined,
            .writer = undefined,
        };
    }

    pub fn startTls(c: *Client, io: Io) !void {
        const now = Io.Clock.real.now(io);
        c.tls = try .init(&c.reader.interface, &c.writer.interface, .{
            .host = c.host,
            .entropy = undefined,
            .r_b = c.tls_buffer[0 .. c.tls_buffer.len / 2],
            .w_b = c.tls_buffer[c.tls_buffer.len / 2 ..],
            .now = now,
        });
    }

    fn helloWrite(c: *Client) !void {
        //const r = c.getReader();
        try c.write("EHLO ", "local.srctree.gr.ht");
        try c.flush();
        //try r.fillMore();
        while (try c.takeAnswer()) |ans| {
            if (!ans.continues) break;
        }
        try c.write("", "NOOP");
        try c.flush();
        while (try c.takeAnswer()) |ans| {
            if (!ans.continues) break;
        }
    }

    pub fn hello(c: *Client, io: Io) !void {
        c.reader = c.stream.reader(io, &c.read_bytes);
        c.writer = c.stream.writer(io, &c.write_bytes);
        _ = (try c.takeAnswer()) orelse return error.IntroHeaderMissing;

        try c.helloWrite();
        try c.write("", "STARTTLS");
        try c.flush();
        while (try c.takeAnswer()) |ans| {
            if (!ans.continues) break;
        }
        try c.startTls(io);
        try c.helloWrite();
        try c.sendMessage(.simple(
            "<srctree-admin@gr.ht>",
            "<srctree@evilcorp.ltd>",
            "subject",
            "msg",
        ));
    }

    fn message(c: *Client, envelope: Envelope) !void {
        _ = envelope;
        try c.write("",
            //\\From: "Saf Trustmenton" <srctree@evilcorp.ltd>
            \\From: "Smrt Sorsadmen" <srctree-admin@gr.ht>
        );
        try c.write("",
            //\\To: "Smrt Sorsadmen" <srctree-admin@gr.ht>
            \\To: "Saf Trustmenton" <srctree@evilcorp.ltd>
        );
        try c.write("Date: Thu, 5 Nov 2026 04:32:44 -0000", "");
        try c.write("Subject: New feature idea for srctree", "");
        try c.write("", "");
        try c.write("Hello Admin", "");
        try c.write("", "");
        try c.write("Would you like to add my feature?", "");
        try c.write("I eagerly await your acceptance, so we", "");
        try c.write("can discuss licensing terms and fees!", "");
        try c.write("", "");
        try c.write("Your friend,", "");
        try c.write("Bob", "");
        try c.write("", "");
        try c.write(".", "");
        try c.flush();
    }

    pub fn sendMessage(c: *Client, msg: Message) !void {
        std.debug.assert(msg.mailbox.from.len > 5);
        try c.write("MAIL FROM:", msg.mailbox.from);
        try c.flush();
        while (try c.takeAnswer()) |ans| {
            if (ans.code == .@"530") return error.TlsRequired;
            if (!ans.continues) break;
        }

        std.debug.assert(msg.mailbox.to.len > 0);
        for (msg.mailbox.to) |to| {
            std.debug.assert(to.len > 5);
            try c.write("RCPT TO:", to);
            try c.flush();
            while (try c.takeAnswer()) |ans| if (!ans.continues) break;
        }

        try c.write("DATA", "");
        try c.flush();
        while (try c.takeAnswer()) |ans| if (!ans.continues) break;
        try c.message(msg.envelope);
        while (try c.takeAnswer()) |ans| if (!ans.continues) break;
        try c.write("QUIT", "");
        try c.flush();
        while (try c.takeAnswer()) |ans| if (!ans.continues) break;
    }

    fn flush(c: *Client) !void {
        if (c.tls) |*t| try t.client.writer.flush();
        try c.writer.interface.flush();
    }

    fn write(c: *Client, verb: []const u8, noun: []const u8) !void {
        std.debug.print("write: '{s}{s}\n", .{ verb, noun });
        if (c.tls) |*t| {
            try t.client.writer.print("{s}{s}\r\n", .{ verb, noun });
        } else try c.writer.interface.print("{s}{s}\r\n", .{ verb, noun });
    }

    pub fn getReader(c: *Client) *Io.Reader {
        if (c.tls) |_| return &c.tls.?.client.reader;
        return &c.reader.interface;
    }

    fn getLine(r: *Io.Reader) ![]const u8 {
        if (r.peekGreedy(2)) |rest| {
            if (findScalar(u8, rest, '\n')) |idx| {
                if (idx == 0 or rest[idx - 1] != '\r') return error.InvalidAnswer;
                r.toss(idx + 1);
                return rest[0 .. idx - 1];
            } else return error.OutOfSpace;
        } else |e| return e;
        return error.Unreachable;
    }

    fn takeAnswer(c: *Client) !?Answer {
        const r = c.getReader();
        const code_str = r.peek(4) catch return null;
        if (code_str[3] != ' ' and code_str[3] != '-') return error.InvalidAnswer;
        for (code_str[0..3]) |chr| switch (chr) {
            '0'...'9' => {},
            else => return error.InvalidAnswer,
        };
        r.toss(4);
        const continues = code_str[3] == '-';

        std.debug.print("read:  '{s}", .{code_str});
        switch (try Code.init(code_str[0..3].*)) {
            .@"220" => {
                const line = try getLine(r);
                std.debug.print("{s}'\n", .{line});
                return .{
                    .continues = continues,
                    .code = .@"220",
                    .bytes = line,
                };
            },
            .@"221" => {
                const line = try getLine(r);
                std.debug.print("{s}'\n", .{line});
                return .{
                    .continues = continues,
                    .code = .@"221",
                    .bytes = line,
                };
            },
            .@"250" => {
                const line = try getLine(r);
                std.debug.print("{s}'\n", .{line});
                return .{
                    .continues = continues,
                    .code = .@"250",
                    .bytes = line,
                };
            },
            .@"354" => {
                const line = try getLine(r);
                std.debug.print("{s}'\n", .{line});
                return .{
                    .continues = continues,
                    .code = .@"354",
                    .bytes = line,
                };
            },
            .@"400" => {
                const line = try getLine(r);
                std.debug.print("{s}'\n", .{line});
                unreachable;
            },
            .@"421" => {
                const line = try getLine(r);
                std.debug.print("{s}'\n", .{line});
                return .{
                    .continues = continues,
                    .code = .@"421",
                    .bytes = line,
                };
            },
            .@"450", .@"451" => {
                const line = try getLine(r);
                std.debug.print("{s}'\n", .{line});
                unreachable;
            },
            .@"500" => {
                const line = try getLine(r);
                std.debug.print("{s}'\n", .{line});
                return .{
                    .continues = continues,
                    .code = .@"500",
                    .bytes = line,
                };
            },
            .@"530" => {
                const line = try getLine(r);
                std.debug.print("{s}'\n", .{line});
                return .{
                    .continues = continues,
                    .code = .@"530",
                    .bytes = line,
                };
            },
            _ => return error.UnknownCode,
        }

        comptime unreachable;
    }
};

pub const Code = enum(u16) {
    //  2yz  Positive Completion reply
    //  3yz  Positive Intermediate reply
    //  4yz  Transient Negative Completion reply
    //  5yz  Permanent Negative Completion reply

    //  x0z  Syntax: syntax errors, and unimplemented or superfluous commands.
    //  x1z  Information: These are replies to requests for information, such as status or help.
    //  x2z  Connections: These are replies referring to the transmission channel.
    //  x3z  Unspecified.
    //  x4z  Unspecified.
    //  x5z  Mail system replies: indicate the status of the receiver mail system

    /// Hello
    @"220",
    /// Goodbye
    @"221",
    /// Continues
    @"250",
    /// Send data
    @"354",

    @"400",
    /// Timeout
    @"421",
    @"450",
    @"451",
    @"500",
    @"530",

    _,

    pub fn init(str: [3]u8) !Code {
        return switch (str[0]) {
            // ack
            '2' => switch (str[1]) {
                '2' => switch (str[2]) {
                    '0' => .@"220",
                    '1' => .@"221",
                    else => error.NotImplemented,
                },
                '5' => switch (str[2]) {
                    '0' => .@"250",
                    else => error.NotImplemented,
                },
                else => error.NotImplemented,
            },
            // cont
            '3' => switch (str[1]) {
                '5' => switch (str[2]) {
                    '4' => .@"354",
                    else => error.NotImplemented,
                },
                else => error.NotImplemented,
            },
            // nak
            '4' => switch (str[1]) {
                '0' => switch (str[2]) {
                    '0' => .@"400",
                    else => error.NotImplemented,
                },
                '5' => switch (str[2]) {
                    '0' => .@"450",
                    '1' => .@"451",
                    else => error.NotImplemented,
                },
                else => error.NotImplemented,
            },
            // err
            '5' => switch (str[1]) {
                '0' => switch (str[2]) {
                    '0' => .@"500",
                    else => error.NotImplemented,
                },
                '3' => switch (str[2]) {
                    '0' => .@"530",
                    else => error.NotImplemented,
                },
                else => error.NotImplemented,
            },

            else => error.UnknownCode,
        };
    }
};

pub const Mailbox = struct {
    from: []const u8,
    to: []const []const u8,

    pub fn mb(from: []const u8, to: []const u8) !Envelope {
        return .{
            .from = from,
            .to = &.{to},
        };
    }
};

pub const Envelope = struct {
    from: ?Header,
    to: ?Header,
    date: ?Header,
    subject: ?Header,
    extra: []const Header = &.{},
    msg: []const u8,

    pub const Header = []const u8;

    pub fn simple(from: []const u8, to: []const u8, subject: []const u8, msg: []const u8) Envelope {
        return .{
            .from = from,
            .to = to,
            .date = null, // FIXME
            .subject = subject,
            .msg = msg,
        };
    }
};

pub const Message = struct {
    mailbox: Mailbox,
    envelope: Envelope,

    pub fn simple(from: []const u8, to: []const u8, subject: []const u8, msg: []const u8) Message {
        return .{
            .mailbox = .{ .from = from, .to = &.{to} },
            .envelope = .{
                .from = from,
                .to = to,
                .date = null, // FIXME
                .subject = subject,
                .msg = msg,
            },
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var client: Client = try .init("gr.ht", .{
        .ip4 = .{
            .bytes = .{ 127, 0, 0, 1 },
            .port = 587,
        },
    }, init.io);

    try client.hello(init.io);

    return error.EndOfMain;
}

test {
    _ = &Client;
    _ = &Mailbox;
    _ = &Envelope;
    _ = &Message;
}

const std = @import("std");
const tls = std.crypto.tls;
const Io = std.Io;
const net = Io.net;
const findScalar = std.mem.findScalar;
const eql = std.mem.eql;
