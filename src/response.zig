const std = @import("std");
const Allocator = std.mem.Allocator;

const Request = @import("request.zig");
const Headers = @import("headers.zig");
const UserData = @import("user-data.zig");
const Template = @import("template.zig").Template;

const Response = @This();

const ONESHOT_SIZE = 14720;

const Pair = struct {
    name: []const u8,
    val: []const u8,
};

pub const TransferMode = enum {
    static,
    streaming,
    proxy,
    proxy_streaming,
};

const Phase = enum {
    created,
    headers,
    body,
    closed,
};

const Downstream = enum {
    buffer,
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

//alloc: Allocator,
request: *Request,
headers: Headers,
phase: Phase = .created,
tranfer_mode: TransferMode = .static,
downstream: union(Downstream) {
    buffer: std.io.BufferedWriter(ONESHOT_SIZE, std.net.Stream.Writer),
    zwsgi: std.net.Stream.Writer,
    http: std.http.Server.Response.Writer,
},
status: std.http.Status = .internal_server_error,
/// The correct way to access post_data is with postData until this API
/// officially becomes stable
usr_data: ?UserData.UserData = null,

pub fn init(a: Allocator, req: *Request) Response {
    var res = Response{
        //.alloc = a,
        .request = req,
        .headers = Headers.init(a),
        .downstream = switch (req.raw_request) {
            .zwsgi => |*z| .{ .zwsgi = z.acpt.stream.writer() },
            .http => |*h| .{ .http = h.writer() },
        },
    };
    res.headersInit() catch @panic("unable to create Response obj");
    return res;
}

pub fn postData(res: *Response) ?UserData.UserData {
    return res.post_data;
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
    switch (res.downstream) {
        .http => {
            res.request.raw_request.http.transfer_encoding = .chunked;
            res.phase = .headers;
            return res.request.raw_request.http.do();
        },
        else => {},
    }

    try res.sendHeaders();
    _ = try res.write("\r\n");
}

pub fn sendHeaders(res: *Response) !void {
    res.phase = .headers;
    _ = switch (res.status) {
        .ok => try res.write("HTTP/1.1 200 OK\r\n"),
        .found => try res.write("HTTP/1.1 302 Found\r\n"),
        .forbidden => try res.write("HTTP/1.1 403 Forbidden\r\n"),
        .not_found => try res.write("HTTP/1.1 404 Not Found\r\n"),
        else => return Error.UnknownStatus,
    };
    var itr = res.headers.index.iterator();
    while (itr.next()) |header| {
        var buf: [512]u8 = undefined;

        // TODO descend
        const b = try std.fmt.bufPrint(&buf, "{s}: {s}\r\n", .{ header.key_ptr.*, header.value_ptr.str });
        _ = try res.write(b);
    }
    _ = try res.write("Transfer-Encoding: chunked\r\n");
}

pub fn redirect(res: *Response, loc: []const u8, see_other: bool) !void {
    if (res.phase != .created) return error.WrongPhase;

    try res.writeAll("HTTP/1.1 ");
    if (see_other) {
        try res.writeAll("303 See Other\r\n");
    } else {
        try res.writeAll("302 Found\r\n");
    }

    try res.writeAll("Location: ");
    try res.writeAll(loc);
    try res.writeAll("\r\n\r\n");
}

pub fn send(res: *Response, data: []const u8) !void {
    switch (res.phase) {
        .created => try res.start(),
        .headers, .body => {},
        .closed => return Error.ResponseClosed,
    }
    res.phase = .body;
    try res.writeAll(data);
}

pub fn writer(res: *Response) Writer {
    return .{ .context = res };
}

pub fn writeChunk(res: *Response, data: []const u8) !void {
    var size: [0xffff]u8 = undefined;
    const chunk = try std.fmt.bufPrint(&size, "{x}\r\n", .{data.len});
    try res.writeAll(chunk);
    try res.writeAll(data);
    try res.writeAll("\r\n");
}

pub fn writeAll(res: *Response, data: []const u8) !void {
    var index: usize = 0;
    while (index < data.len) {
        index += try write(res, data[index..]);
    }
}

/// Raw writer, use with caution! To use phase checking, use send();
pub fn write(res: *Response, data: []const u8) !usize {
    return switch (res.downstream) {
        .zwsgi => |*w| try w.write(data),
        .http => |*w| try w.write(data),
        .buffer => |*w| try w.write(data),
    };
}

fn flush(res: *Response) !void {
    switch (res.downstream) {
        .buffer => |*w| try w.flush(),
        else => {},
    }
}

pub fn finish(res: *Response) !void {
    res.phase = .closed;
    switch (res.downstream) {
        .http => {
            try res.request.raw_request.http.finish();
        },
        //.zwsgi => |*w| _ = try w.write("0\r\n\r\n"),
        else => {},
    }
    //return res.flush() catch |e| {
    //    std.debug.print("Error on flush :< {}\n", .{e});
    //};
}
