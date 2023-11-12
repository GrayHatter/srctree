const std = @import("std");

const Allocator = std.mem.Allocator;

const Template = @import("template.zig");
const Response = @import("response.zig");
const endpoint = @import("endpoint.zig");
const HTML = @import("html.zig");

const Endpoint = endpoint.Endpoint;
const Error = endpoint.Error;
pub const UriIter = std.mem.SplitIterator(u8, .sequence);

const div = HTML.div;
const span = HTML.span;

pub const Router = *const fn (*UriIter) Error!Endpoint;

pub const MatchRouter = struct {
    name: []const u8,
    match: union(enum) {
        call: Endpoint,
        route: Router,
    },
};

const endpoints = [_]MatchRouter{
    .{ .name = "auth", .match = .{ .call = auth } },
    .{ .name = "bye", .match = .{ .call = bye } },
    .{ .name = "code", .match = .{ .call = endpoint.code } },
    .{ .name = "commits", .match = .{ .call = respond } },
    .{ .name = "hi", .match = .{ .call = respond } },
    .{ .name = "post", .match = .{ .call = post } },
    .{ .name = "repo", .match = .{ .route = endpoint.repo } },
    .{ .name = "repos", .match = .{ .route = endpoint.repo } },
    .{ .name = "tree", .match = .{ .call = respond } },
    .{ .name = "user", .match = .{ .call = endpoint.commitFlex } },
};

fn sendMsg(r: *Response, msg: []const u8) !void {
    //r.transfer_encoding = .{ .content_length = msg.len };
    try r.start();
    try r.write(msg);
    try r.finish();
}

fn bye(r: *Response, _: *UriIter) Error!void {
    const MSG = "bye!\n";
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
    };
    return Error.AndExit;
}

fn auth(r: *Response, _: *UriIter) Error!void {
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

fn notfound(r: *Response, _: *UriIter) Error!void {
    r.status = .not_found;
    const MSG = Template.find("index.html").blob;
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
        return Error.AndExit;
    };
}

fn respond(r: *Response, _: *UriIter) Error!void {
    r.headersAdd("connection", "keep-alive") catch return Error.ReqResInvalid;
    r.headersAdd("content-type", "text/plain") catch return Error.ReqResInvalid;
    const MSG = "Hi, mom!\n";
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
        return Error.AndExit;
    };
}

fn default(r: *Response, _: *UriIter) Error!void {
    const MSG = Template.find("index.html").blob;
    sendMsg(r, MSG) catch |e| switch (e) {
        error.NotWriteable => unreachable,
        else => {
            std.log.err("Unexpected error while responding [{}]\n", .{e});
            return Error.AndExit;
        },
    };
}

fn post(r: *Response, _: *UriIter) Error!void {
    const MSG = Template.find("post.html").blob;
    sendMsg(r, MSG) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
        return Error.AndExit;
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn router(uri: *UriIter, comptime routes: []const MatchRouter) Endpoint {
    const search = uri.next() orelse return notfound;
    inline for (routes) |ep| {
        if (eql(search, ep.name)) {
            switch (ep.match) {
                .call => |call| return call,
                .route => |route| {
                    return route(uri) catch |err| switch (err) {
                        error.Unrouteable => return notfound,
                        else => unreachable,
                    };
                },
            }
        }
    }
    return notfound;
}

pub fn baseRouter(r: *Response, uri: []const u8) Error!void {
    std.debug.assert(uri[0] == '/');
    var itr = std.mem.split(u8, uri[1..], "/");
    if (uri.len <= 1) return default(r, &itr);
    const route: Endpoint = router(&itr, &endpoints);
    return route(r, &itr);
}
