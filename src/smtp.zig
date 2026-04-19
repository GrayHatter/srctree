pub const Client = struct {
    host: []const u8,
    addr: std.Io.net.IpAddress,
    stream: std.Io.net.Stream,
    tls: ?Tls = null,

    pub const Tls = struct {
        client: std.crypto.tls.Client,
        stream: *std.Io.net.Stream,
        reader: std.Io.net.Stream.Reader,
        writer: std.Io.net.Stream.Writer,

        pub fn init() Tls {
            return undefined;
        }
    };
};

pub const Mailbox = struct {
    from: []const u8,
    to: []const []const u8 = &.{},
};

pub const Envelope = struct {
    headers: Headers,
    message: []const u8,

    pub const Headers = struct {
        from: ?Header,
        to: ?Header,
        date: ?Header,
        subject: ?Header,
        extra: []const Header = &.{},
    };

    pub const Header = []const u8;
};

pub const Message = struct {
    mailbox: Mailbox,
    data: Envelope,
};

pub fn main(init: std.process.Init) !void {
    _ = init;
    return error.notimplemented;
}

test {
    _ = &Client;
    _ = &Mailbox;
    _ = &Envelope;
    _ = &Message;
}

const std = @import("std");
