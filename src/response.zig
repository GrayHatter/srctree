const std = @import("std");
const Allocator = std.mem.Allocator;
const AnyWriter = std.io.AnyWriter;

const Request = @import("request.zig");
const Headers = @import("headers.zig");
//const RequestData = @import("request_data.zig");
const Template = @import("template").Template;

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

//request: *Request,
headers: ?Headers = null,
tranfer_mode: TransferMode = .static,
// This is just bad code, but I need to give the sane implementation more thought
http_response: ?std.http.Server.Response = null,
downstream: union(Downstream) {
    buffer: std.io.BufferedWriter(ONESHOT_SIZE, std.net.Stream.Writer),
    zwsgi: std.net.Stream.Writer,
    http: std.io.AnyWriter,
},
status: ?std.http.Status = null,

pub fn init(a: Allocator, req: *Request) !Response {
    var res = Response{
        //.alloc = a,
        .headers = Headers.init(a),
        .http_response = switch (req.raw_request) {
            .zwsgi => null,
            .http => |*h| h.respondStreaming(.{
                .send_buffer = try a.alloc(u8, 0xffff),
                .respond_options = .{
                    .transfer_encoding = .chunked,
                    .keep_alive = false,
                },
            }),
        },
        .downstream = switch (req.raw_request) {
            .zwsgi => |*z| .{ .zwsgi = z.acpt.stream.writer() },
            .http => .{ .http = undefined },
        },
    };
    if (res.http_response) |*h| res.downstream.http = h.writer();
    res.headersInit() catch @panic("unable to create Response obj");
    return res;
}

fn headersInit(res: *Response) !void {
    try res.headersAdd("Server", "zwsgi/0.0.0");
    try res.headersAdd("Content-Type", "text/html; charset=utf-8"); // Firefox is trash
}

pub fn headersAdd(res: *Response, comptime name: []const u8, value: []const u8) !void {
    if (res.headers) |*headers| {
        try headers.add(name, value);
    } else return Error.HeadersFinished;
}

pub fn start(res: *Response) !void {
    if (res.headers == null) return Error.WrongPhase;
    if (res.status == null) res.status = .ok;
    switch (res.downstream) {
        .http => {
            // I don't know why/where the writer goes invalid, but I'll probably
            // fix it later?
            if (res.http_response) |*h| res.downstream.http = h.writer();
            try res.sendHeaders();
        },
        else => {
            try res.sendHeaders();
            _ = try res.write("\r\n");
        },
    }
}

fn sendHTTPHeader(res: *Response) !void {
    if (res.status == null) res.status = .ok;
    _ = switch (res.status.?) {
        .ok => try res.write("HTTP/1.1 200 OK\r\n"),
        .found => try res.write("HTTP/1.1 302 Found\r\n"),
        .forbidden => try res.write("HTTP/1.1 403 Forbidden\r\n"),
        .not_found => try res.write("HTTP/1.1 404 Not Found\r\n"),
        .internal_server_error => try res.write("HTTP/1.1 500 Internal Server Error\r\n"),
        else => return Error.UnknownStatus,
    };
}

pub fn sendHeaders(res: *Response) !void {
    switch (res.downstream) {
        .http => try res.http_response.?.flush(),
        .zwsgi, .buffer => {
            if (res.headers) |*headers| {
                try res.sendHTTPHeader();
                var itr = headers.index.iterator();
                while (itr.next()) |header| {
                    var buf: [512]u8 = undefined;
                    const b = try std.fmt.bufPrint(&buf, "{s}: {s}\r\n", .{
                        header.key_ptr.*,
                        header.value_ptr.str,
                    });
                    _ = try res.write(b);
                }
                _ = try res.write("Transfer-Encoding: chunked\r\n");
            } else return error.WrongPhase;
        },
    }
    res.headers = null;
}

pub fn redirect(res: *Response, loc: []const u8, see_other: bool) !void {
    if (res.headers == null) return error.WrongPhase;

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

/// Do not use
/// TODO remove
pub fn send(res: *Response, data: []const u8) !void {
    if (res.headers != null) try res.start();
    try res.writeAll(data);
    return res.finish();
}

pub fn writer(res: *const Response) Writer {
    return .{ .context = res };
}

pub fn anyWriter(res: *const Response) AnyWriter {
    return .{
        .context = res,
        .writeFn = typeErasedWrite,
    };
}

pub fn writeChunk(res: *const Response, data: []const u8) !void {
    comptime unreachable;
    var size: [0xff]u8 = undefined;
    const chunk = try std.fmt.bufPrint(&size, "{x}\r\n", .{data.len});
    try res.writeAll(chunk);
    try res.writeAll(data);
    try res.writeAll("\r\n");
}

pub fn writeAll(res: *const Response, data: []const u8) !void {
    var index: usize = 0;
    while (index < data.len) {
        index += try write(res, data[index..]);
    }
}

pub fn typeErasedWrite(opq: *const anyopaque, data: []const u8) anyerror!usize {
    const cast: *const Response = @alignCast(@ptrCast(opq));
    return try write(cast, data);
}

/// Raw writer, use with caution! To use phase checking, use send();
pub fn write(res: *const Response, data: []const u8) !usize {
    return switch (res.downstream) {
        .zwsgi => |*w| try w.write(data),
        .http => |*w| return try w.write(data),
        .buffer => {
            var bff: *Response = @constCast(res);
            return try bff.write(data);
        },
    };
}

fn flush(res: *Response) !void {
    switch (res.downstream) {
        .buffer => |*w| try w.flush(),
        .http => |*h| h.flush(),
        else => {},
    }
}

pub fn finish(res: *Response) !void {
    switch (res.downstream) {
        .http => {
            if (res.http_response) |*h| try h.endChunked(.{});
        },
        //.zwsgi => |*w| _ = try w.write("0\r\n\r\n"),
        else => {},
    }
    //return res.flush() catch |e| {
    //    std.debug.print("Error on flush :< {}\n", .{e});
    //};
}
