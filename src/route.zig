const std = @import("std");
const endpoint = @import("endpoint.zig");
const Endpoint = endpoint.Endpoint;
const Error = endpoint.Error;

const Template = @import("template.zig");

const Response = @import("response.zig");

const endpoints = [_]struct {
    name: []const u8,
    call: Endpoint,
}{
    .{ .name = "/", .call = default },
    .{ .name = "/hi", .call = respond },
    .{ .name = "/bye", .call = bye },
    .{ .name = "/auth", .call = auth },
    .{ .name = "/commits", .call = respond },
    .{ .name = "/tree", .call = respond },
};

fn sendMsg(r: *Response, msg: []const u8) !void {
    //r.transfer_encoding = .{ .content_length = msg.len };
    try r.start();
    try r.write(msg);
    try r.finish();
}

fn bye(r: *Response, _: []const u8) Error!void {
    const MSG = "bye!\n";
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
    };
    return Error.AndExit;
}

fn auth(r: *Response, _: []const u8) Error!void {
    std.debug.print("auth is {}\n", .{r.request.auth});
    if (r.request.auth.valid()) {
        r.status = .ok;
        sendMsg(r, "Oh hi! Welcome back\n") catch |e| {
            std.log.err("Auth Failed somehow [{}]\n", .{e});
            return Error.AndExit;
        };
        return;
    }
    r.status = .forbidden;
    sendMsg(r, "Kindly Shoo!\n") catch |e| {
        std.log.err("Auth Failed somehow [{}]\n", .{e});
        return Error.AndExit;
    };
}

fn notfound(r: *Response, _: []const u8) Error!void {
    r.status = .not_found;
    r.start() catch unreachable;
}

fn respond(r: *Response, _: []const u8) Error!void {
    r.headersAdd("connection", "keep-alive") catch return Error.ReqResInvalid;
    r.headersAdd("content-type", "text/plain") catch return Error.ReqResInvalid;
    const MSG = "Hi, mom!\n";
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
        return Error.AndExit;
    };
}

fn default(r: *Response, _: []const u8) Error!void {
    const MSG = Template.builtin[0].blob;
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
