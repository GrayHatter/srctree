const std = @import("std");
const Allocator = std.mem.Allocator;

const Request = @import("request.zig");

const Response = @This();

const ONESHOT_SIZE = 14720;

const Pair = struct {
    name: []const u8,
    val: []const u8,
};

const HeaderList = std.ArrayList(Pair);

const Phase = enum {
    created,
    headers,
    body,
    closed,
};

const Error = error{
    WrongPhase,
    HeadersFinished,
    ResponseClosed,
    UnknownStatus,
};

alloc: Allocator,
request: *const Request,
headers: HeaderList,
phase: Phase = .created,
writer: std.io.BufferedWriter(ONESHOT_SIZE, std.net.Stream.Writer),
status: std.http.Status = .internal_server_error,

pub fn init(a: Allocator, stream: std.net.Stream, req: *const Request) Response {
    return .{
        .alloc = a,
        .request = req,
        .headers = HeaderList.init(a),
        .writer = .{ .unbuffered_writer = stream.writer() },
    };
}

pub fn headerAdd(res: *Response, name: []const u8, value: []const u8) !void {
    if (res.phase != .created) return try res.headers.append(.{ .name = name, .val = value });
}

pub fn start(res: *Response) !void {
    if (res.phase != .created) return Error.WrongPhase;
    if (res.status == .internal_server_error) res.status = .ok;
    try res.sendHeaders();
}

fn sendHeaders(res: *Response) !void {
    res.phase = .headers;
    switch (res.status) {
        .ok => try res.write("HTTP/1.1 200 Found\n"),
        .found => try res.write("HTTP/1.1 302 Found\n"),
        .forbidden => try res.write("HTTP/1.1 403 Forbidden\n"),
        .not_found => try res.write("HTTP/1.1 404 Not Found\n"),
        else => return Error.UnknownStatus,
    }
    for (res.headers.items) |header| {
        var buf: [512]u8 = undefined;
        const b = try std.fmt.bufPrint(&buf, "{s}: {s}\n", .{ header.name, header.val });
        try res.write(b);
    }
    try res.write("\n");
}

pub fn send(res: *Response, data: []const u8) !void {
    switch (res.phase) {
        .created => try res.start(),
        .headers, .body => {},
        .close => return Error.ResponseClosed,
    }
    res.phase = .body;
    try res.write(data);
}

/// Raw writer, use with caution! To use phase checking, use send();
pub fn write(res: *Response, data: []const u8) !void {
    _ = try res.writer.write(data);
}

pub fn finish(res: *Response) !void {
    res.phase = .closed;
    return res.writer.flush();
}
