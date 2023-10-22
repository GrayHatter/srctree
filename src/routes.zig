const std = @import("std");

const Allocator = std.mem.Allocator;

const Template = @import("template.zig");
const Response = @import("response.zig");
const endpoint = @import("endpoint.zig");
const HTML = @import("html.zig");

const Endpoint = endpoint.Endpoint;
const Error = endpoint.Error;

const div = HTML.div;
const span = HTML.span;

pub const Router = *const fn (*Response, []const u8) Error!void;

const endpoints = [_]struct {
    name: []const u8,
    match: union(enum) {
        call: Endpoint,
        route: Router,
    },
}{
    .{ .name = "/", .match = .{ .call = default } },
    .{ .name = "/auth", .match = .{ .call = auth } },
    .{ .name = "/bye", .match = .{ .call = bye } },
    .{ .name = "/code", .match = .{ .call = endpoint.code } },
    .{ .name = "/commits", .match = .{ .call = respond } },
    .{ .name = "/hi", .match = .{ .call = respond } },
    .{ .name = "/repo/", .match = .{ .route = endpoint.repoList } },
    .{ .name = "/repos", .match = .{ .call = endpoint.repoList } },
    .{ .name = "/tree", .match = .{ .call = respond } },
    .{ .name = "/user", .match = .{ .call = endpoint.commitFlex } },
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
    const MSG = Template.find("index.html").blob;
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
        return Error.AndExit;
    };
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
    const MSG = Template.find("index.html").blob;
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
        return Error.AndExit;
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn router(uri: []const u8) Endpoint {
    inline for (endpoints) |ep| {
        switch (ep.match) {
            .call => |call| {
                if (eql(uri, ep.name)) return call;
            },
            .route => |route| {
                if (eql(uri[0..@min(uri.len, ep.name.len)], ep.name)) return route;
            },
        }
    }
    return notfound;
}
