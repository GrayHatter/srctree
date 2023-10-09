const std = @import("std");
const Server = std.http.Server;
const endpoint = @import("endpoint.zig");
const Endpoint = endpoint.Endpoint;
const Error = endpoint.Error;

const endpoints = [_]struct {
    name: []const u8,
    call: Endpoint,
}{
    .{ .name = "/", .call = respond },
    .{ .name = "/bye", .call = bye },
    .{ .name = "/commits", .call = respond },
    .{ .name = "/tree", .call = respond },
};

fn sendMsg(r: *Server.Response, msg: []const u8) !void {
    r.transfer_encoding = .{ .content_length = msg.len };

    try r.do();
    try r.writeAll(msg);
    try r.finish();
}

fn bye(r: *Server.Response, _: []const u8) Error!void {
    const MSG = "bye!\n";
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
    };
    return Error.AndExit;
}

fn notfound(r: *Server.Response, _: []const u8) Error!void {
    r.status = .not_found;
    r.do() catch unreachable;
}

fn respond(r: *Server.Response, _: []const u8) Error!void {
    if (r.request.headers.contains("connection")) {
        try r.headers.append("connection", "keep-alive");
    }
    try r.headers.append("content-type", "text/plain");
    const MSG = "Hi, mom!\n";
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
        return Error.AndExit;
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn route(uri: []const u8) Endpoint {
    inline for (endpoints) |ep| {
        if (eql(uri, ep.name)) return ep.call;
    }
    return notfound;
}
