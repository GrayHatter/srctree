//! SMTP

pub const default_port = 587;
pub const default_sender_host = "local.srctree.gr.ht";

pub fn sendMsg(msg: Message, io: Io) !void {
    const from_email: email.Address = try .init(msg.from.?);
    const from_host = try from_email.host();

    const envl = msg.envelope();
    const host: net.HostName = try .init(from_host);

    var client: Client = try .initFromHost(host, io);
    try client.hello(std.testing.io);
    try client.deliver(envl);
    try client.quit();
}

test sendMsg {
    const msg: Message = .{
        .to = "\"Smrt Sorsadmen\" <srctree-admin@gr.ht>",
        .from = "\"Saf Trustmenton\" <srctree@gr.ht>",
        .date = "Thu, 5 Nov 2026 04:32:44 -0000",
        .subject = "New feature idea for srctree",
        .body =
        \\Hello Admin
        \\
        \\Would you like to add my feature?
        \\I eagerly await your acceptance, so we
        \\can discuss licensing terms and fees!
        \\
        \\Your friend,
        \\Bob
        \\
        ,
    };
    try sendMsg(msg, std.testing.io);
}

/// Server not yet implemented, namespace for Settings
pub const Server = struct {
    const Settings = struct {
        pipelining: bool,
        start_tls: bool,
        size: usize,
        vrfy: bool,
        etrn: bool,
        enhanced_status_codes: bool,
        mime_bit8: bool,
        dsn: bool,
        smtp_utf8: bool,
        chunking: bool,
        auth: Auth,

        pub const Auth = struct {
            plain: bool = true,
            login: bool = false,
            digest_md5: bool = false,
        };

        pub const default: Settings = .{
            .start_tls = false,
            .pipelining = false,
            .size = 0,
            .vrfy = false,
            .etrn = false,
            .enhanced_status_codes = false,
            .mime_bit8 = false,
            .dsn = false,
            .smtp_utf8 = false,
            .chunking = false,
            .auth = .{},
        };
    };
};

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

    srv: Server.Settings = .default,

    pub const Tls = struct {
        reader: *Io.Reader,
        writer: *Io.Writer,
        client: std.crypto.tls.Client,
        bundle: std.crypto.Certificate.Bundle = .empty,

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

    pub fn initFromHost(host: net.HostName, io: Io) !Client {
        const stream = try host.connect(io, default_port, .{ .mode = .stream });
        return .{
            .host = host.bytes,
            .addr = stream.socket.address,
            .stream = stream,
            .reader = undefined,
            .writer = undefined,
        };
    }

    pub fn startTls(c: *Client, io: Io) !void {
        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);
        const now = Io.Clock.real.now(io);
        c.tls = try .init(&c.reader.interface, &c.writer.interface, .{
            .host = c.host,
            .entropy = &entropy,
            .r_b = c.tls_buffer[0 .. c.tls_buffer.len / 2],
            .w_b = c.tls_buffer[c.tls_buffer.len / 2 ..],
            .now = now,
        });
    }

    pub fn deliver(c: *Client, envl: Envelope) !void {
        std.debug.assert(envl.from.bytes.len > 5);
        try c.writePrefix("MAIL FROM:", try envl.from.email());
        try c.flush();
        while (try c.takeAnswer()) |ans| {
            if (ans.code == .@"530") return error.TlsRequired;
            if (!ans.continues) break;
        }

        std.debug.assert(envl.to.bytes.len > 0);
        try c.writePrefix("RCPT TO:", try envl.to.email());
        try c.flush();
        while (try c.takeAnswer()) |ans| if (!ans.continues) break;

        try c.writeMessage(envl.msg);
    }

    pub fn quit(c: *Client) !void {
        try c.write("QUIT");
        try c.flush();
        while (try c.takeAnswer()) |ans| if (!ans.continues) break;
    }

    fn writeMessage(c: *Client, msg: Message) !void {
        try c.write("DATA");
        try c.flush();
        while (try c.takeAnswer()) |ans| if (!ans.continues) break;

        try c.print("{f}", .{msg});

        try c.write(".");
        try c.flush();
        while (try c.takeAnswer()) |ans| if (!ans.continues) break;
    }

    fn writeHello(c: *Client) !void {
        try c.writePrefix("EHLO ", default_sender_host);
        try c.flush();
        while (try c.takeAnswer()) |ans| {
            if (eql(u8, ans.bytes, "PIPELINING")) {
                c.srv.pipelining = true;
            } else if (startsWith(u8, ans.bytes, "SIZE ")) {
                // TODO
            } else if (eql(u8, ans.bytes, "VRFY")) {
                c.srv.vrfy = true;
            } else if (eql(u8, ans.bytes, "ETRN")) {
                c.srv.etrn = true;
            } else if (startsWith(u8, ans.bytes, "AUTH ")) {
                // TODO
            } else if (eql(u8, ans.bytes, "STARTTLS")) {
                c.srv.start_tls = true;
            } else if (eql(u8, ans.bytes, "ENHANCEDSTATUSCODES")) {
                c.srv.start_tls = true;
            } else if (eql(u8, ans.bytes, "8B.bytesITMIME")) {
                c.srv.start_tls = true;
            } else if (eql(u8, ans.bytes, "DSN")) {
                c.srv.dsn = true;
            } else if (eql(u8, ans.bytes, "SMTPUTF8")) {
                c.srv.smtp_utf8 = true;
            } else if (eql(u8, ans.bytes, "CHUNKING")) {
                c.srv.chunking = true;
            }
            if (!ans.continues) break;
        }
    }

    pub fn hello(c: *Client, io: Io) !void {
        c.reader = c.stream.reader(io, &c.read_bytes);
        c.writer = c.stream.writer(io, &c.write_bytes);
        _ = (try c.takeAnswer()) orelse return error.IntroHeaderMissing;

        try c.writeHello();
        try c.write("STARTTLS");
        try c.flush();
        while (try c.takeAnswer()) |ans| {
            if (!ans.continues) break;
        }
        try c.startTls(io);
        try c.writeHello();
    }

    fn flush(c: *Client) !void {
        if (c.tls) |*t| try t.client.writer.flush();
        try c.writer.interface.flush();
    }

    fn writePrefix(c: *Client, verb: []const u8, noun: []const u8) !void {
        log.debug("write: '{s}{s}", .{ verb, noun });
        if (c.tls) |*t| {
            try t.client.writer.print("{s}{s}\r\n", .{ verb, noun });
        } else try c.writer.interface.print("{s}{s}\r\n", .{ verb, noun });
    }

    fn write(c: *Client, str: []const u8) !void {
        log.debug("write: '{s}", .{str});
        if (c.tls) |*t| {
            try t.client.writer.print("{s}\r\n", .{str});
        } else try c.writer.interface.print("{s}\r\n", .{str});
    }

    fn print(c: *Client, comptime fmt: []const u8, args: anytype) error{WriteFailed}!void {
        log.debug(fmt, args);
        if (c.tls) |*t| {
            t.client.writer.print(fmt ++ "\r\n", args) catch return error.WriteFailed;
        } else c.writer.interface.print(fmt ++ "\r\n", args) catch return error.WriteFailed;
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

        const line = try getLine(r);
        log.debug("read:  '{s}    {s}", .{ code_str[0..4], line });
        const a: Answer = .{
            .continues = continues,
            .code = try Code.init(code_str[0..3].*),
            .bytes = line,
        };
        switch (a.code) {
            .@"400" => unreachable,
            .@"450", .@"451" => unreachable,
            else => {},
            _ => return error.UnknownCode,
        }
        return a;
    }
};

test Client {
    var client: Client = try .init("gr.ht", .{
        .ip4 = .{
            .bytes = .{ 144, 126, 209, 12 },
            .port = default_port,
        },
    }, std.testing.io);

    try client.hello(std.testing.io);
}

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
    /// OK/Continues
    @"250",
    /// Send data end with `.`
    @"354",

    @"400",
    /// Service Unavailable (Timeout)
    @"421",
    /// Mailbox missing or blocked by policy
    @"450",
    /// Requested action aborted
    @"451",
    /// Syntax Error
    @"500",
    /// Bad sequence of commands
    @"503",
    @"530",
    /// 5.5.4 Unsupported Option
    @"555",

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
                    '3' => .@"503",
                    else => error.NotImplemented,
                },
                '3' => switch (str[2]) {
                    '0' => .@"530",
                    else => error.NotImplemented,
                },
                '5' => switch (str[2]) {
                    '5' => .@"555",
                    else => error.NotImplemented,
                },
                else => error.NotImplemented,
            },

            else => error.UnknownCode,
        };
    }
};

pub const email = struct {
    pub const Address = struct {
        bytes: []const u8,

        pub fn init(addr_str: []const u8) !Address {
            const addr: Address = .{ .bytes = addr_str };
            try addr.validate();
            return addr;
        }

        pub fn validate(_: Address) !void {
            return;
        }

        pub fn host(addr: Address) ![]const u8 {
            const at = find(u8, addr.bytes, "@") orelse return error.InvalidAddress;
            var last = at + 1;
            for (addr.bytes[at + 1 ..]) |chr| switch (chr) {
                'a'...'z', 'A'...'Z', '-', '.' => {
                    last += 1;
                },
                else => break,
            };
            if (last == at) return error.HostMissing;
            return addr.bytes[at + 1 .. last];
        }

        pub fn email(addr: Address) ![]const u8 {
            const at = find(u8, addr.bytes, "<") orelse return error.InvalidAddress;
            const last = find(u8, addr.bytes, ">") orelse return error.InvalidAddress;
            return addr.bytes[at .. last + 1];
        }
    };
};

pub const Answer = struct {
    continues: bool,
    code: Code,
    bytes: []const u8,
};

pub const Mailbox = struct {
    from: []const u8,
    to: []const []const u8,

    pub fn mb(from: []const u8, to: []const u8) !Envelope {
        return .{ .from = from, .to = &.{to} };
    }
};

pub const Envelope = struct {
    from: email.Address,
    to: email.Address,
    msg: Message,

    pub fn simple(from: email.Address, to: email.Address, msg: Message) Envelope {
        return .{ .from = from, .to = to, .mmsg = msg };
    }
};

pub const Message = struct {
    from: ?[]const u8,
    to: ?[]const u8,
    cc: ?[]const u8 = null,
    extra: []const []const u8 = &.{},

    date: []const u8,
    subject: []const u8,

    body: []const u8,

    pub fn simple(from: []const u8, to: []const u8, subject: []const u8, body: []const u8) Message {
        return .{
            .from = from,
            .to = to,
            .date = null, // FIXME
            .subject = subject,
            .body = body,
        };
    }

    /// To and From must be set to valid addresses
    pub fn envelope(m: Message) Envelope {
        return .{
            .to = try .init(m.to.?),
            .from = try .init(m.from.?),
            .msg = m,
        };
    }

    pub fn format(msg: Message, w: *Io.Writer) error{WriteFailed}!void {
        if (msg.from) |from| try w.print("From: {s}\r\n", .{from});
        if (msg.to) |to| try w.print("To: {s}\r\n", .{to});
        if (msg.cc) |cc| try w.print("Cc: {s}\r\n", .{cc});
        for (msg.extra) |extra| {
            try w.writeAll(extra);
            try w.writeAll("\r\n");
        }
        try w.print("Date: {s}\r\n", .{msg.date});
        try w.print("Subject: {s}\r\n", .{msg.subject});
        try w.writeAll("\r\n");

        var r: Io.Reader = .fixed(msg.body);
        while (r.takeDelimiter('\n') catch unreachable) |lineW| {
            const line = trim(u8, lineW, "\r\n");
            if (eql(u8, line, ".."))
                try w.writeAll("..")
            else
                try w.writeAll(line);
            try w.writeAll("\r\n");
        }
    }
};

pub fn main(init: std.process.Init) !void {
    _ = init;
    return error.EndOfMain;
}

test {
    _ = &Code;
    _ = &Answer;
    _ = &Client;
    _ = &Envelope;
    _ = &Mailbox;
    _ = &Message;
    _ = &Server;
    _ = &email;
}

const std = @import("std");
const tls = std.crypto.tls;
const Io = std.Io;
const net = Io.net;
const log = std.log.scoped(.smtp);
const findScalar = std.mem.findScalar;
const find = std.mem.find;
const eql = std.mem.eql;
const trim = std.mem.trim;
const startsWith = std.mem.startsWith;
