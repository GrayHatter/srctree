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

const Downstream = enum {
    zwsgi,
    http,
};

const Error = error{
    WrongPhase,
    HeadersFinished,
    ResponseClosed,
    UnknownStatus,
};

pub const Writer = std.io.Writer(*Response, Error, write);

alloc: Allocator,
request: *const Request,
headers: Headers,
phase: Phase = .created,
dwnstrm: Downstream = .zwsgi,
writer_ctx: union(enum) {
    buffer: std.io.BufferedWriter(ONESHOT_SIZE, std.net.Stream.Writer),
    zwsgi: std.net.Stream.Writer,
    http: std.http.Server.Response.Writer,
},
status: std.http.Status = .internal_server_error,

pub fn init(a: Allocator, req: *Request) Response {
    var res = Response{
        .alloc = a,
        .request = req,
        .headers = Headers.init(a),
        .writer_ctx = switch (req.raw_request) {
            .zwsgi => |*z| .{ .zwsgi = z.acpt.stream.writer() },
            .http => |*h| .{ .http = h.writer() },
        },
    };
    if (req.raw_request == .http) res.dwnstrm = .http;
    //BufferedWriter(ONESHOT_SIZE, std.net.Stream.Writer),
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
    if (res.dwnstrm == .http) {
        var req = @constCast(res.request);
        req.raw_request.http.transfer_encoding = .chunked;
        return req.raw_request.http.do();
    }

    if (res.phase != .created) return Error.WrongPhase;
    if (res.status == .internal_server_error) res.status = .ok;
    try res.sendHeaders();
}

fn sendHeaders(res: *Response) !void {
    res.phase = .headers;
    _ = switch (res.status) {
        .ok => try res.write("HTTP/1.1 200 Found\n"),
        .found => try res.write("HTTP/1.1 302 Found\n"),
        .forbidden => try res.write("HTTP/1.1 403 Forbidden\n"),
        .not_found => try res.write("HTTP/1.1 404 Not Found\n"),
        else => return Error.UnknownStatus,
    };
    var itr = res.headers.index.iterator();
    while (itr.next()) |header| {
        var buf: [512]u8 = undefined;

        // TODO descend
        const b = try std.fmt.bufPrint(&buf, "{s}: {s}\n", .{ header.key_ptr.*, header.value_ptr.str });
        _ = try res.write(b);
    }
    if (res.dwnstrm == .http) {
        _ = try res.write("Transfer-Encoding: chunked\r\n");
    }
    _ = try res.write("\n");
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

pub fn writer(res: *Response) Writer {
    return .{ .context = res };
}

/// Raw writer, use with caution! To use phase checking, use send();
pub fn write(res: *Response, data: []const u8) !void {
    _ = switch (res.writer_ctx) {
        .zwsgi => |*w| try w.write(data),
        .http => |*w| try w.write(data),
        .buffer => |*w| try w.write(data),
    };
    return;
}

fn flush(res: *Response) !void {
    switch (res.writer_ctx) {
        .buffer => |*w| try w.flush(),
        else => {},
    }
}

pub fn finish(res: *Response) !void {
    res.phase = .closed;
    if (res.dwnstrm == .http) {
        var req = @constCast(res.request);
        return req.raw_request.http.connection.writeAll("0\r\n\n\n");
    }
    return res.flush() catch |e| {
        std.debug.print("Error on flush :< {}\n", .{e});
    };
}
