const std = @import("std");
const Allocator = std.mem.Allocator;

const Request = @import("request.zig");
const Headers = @import("headers.zig");

const Response = @This();

const ONESHOT_SIZE = 14720;

const Pair = struct {
    name: []const u8,
    val: []const u8,
};

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
headers: Headers,
phase: Phase = .created,
writer: std.io.BufferedWriter(ONESHOT_SIZE, std.net.Stream.Writer),
status: std.http.Status = .internal_server_error,

pub fn init(a: Allocator, stream: std.net.Stream, req: *const Request) Response {
    var res = Response{
        .alloc = a,
        .request = req,
        .headers = Headers.init(a),
        .writer = .{ .unbuffered_writer = stream.writer() },
    };

    res.headersInit() catch @panic("unable to create Response obj");
    return res;
}

fn headersInit(res: *Response) !void {
    try res.headersAdd("Server", "zwsgi/0.0.0");
    try res.headersAdd("Content-Type", "text/html; charset=utf-8"); // Firefox is trash
}

pub fn headersAdd(res: *Response, comptime name: []const u8, value: []const u8) !void {
    if (res.phase != .created) return Error.HeadersFinished;
    try res.headers.add(name, value);
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
    var itr = res.headers.index.iterator();
    while (itr.next()) |header| {
        var buf: [512]u8 = undefined;

        // TODO descend
        const b = try std.fmt.bufPrint(&buf, "{s}: {s}\n", .{ header.key_ptr.*, header.value_ptr.str });
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
    return res.writer.flush() catch |e| {
        std.debug.print("Error on flush :< {}\n", .{e});
    };
}
