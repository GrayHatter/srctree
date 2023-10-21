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
    .{ .name = "/code", .match = .{ .call = code } },
    .{ .name = "/commits", .match = .{ .call = respond } },
    .{ .name = "/hi", .match = .{ .call = respond } },
    .{ .name = "/list", .match = .{ .call = endpoint.repoList } },
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

fn code(r: *Response, _: []const u8) Error!void {
    var tmpl = Template.find("code.html");
    tmpl.alloc = r.alloc;

    HTML.init(r.alloc);
    defer HTML.raze();

    const src = @embedFile(@src().file[4..]);
    const count = std.mem.count(u8, src, "\n");

    var linens = try r.alloc.alloc([]u8, count + 1);
    defer r.alloc.free(linens);
    for (0..count + 1) |i| {
        linens[i] = try std.fmt.allocPrint(r.alloc, "<linenum>{}</linenum>\n", .{i});
    }
    defer for (linens) |line| r.alloc.free(line);
    var lnums = try std.mem.join(r.alloc, "", linens);
    tmpl.addVar("lines", lnums) catch return Error.Unknown;

    var lines = try r.alloc.alloc([]u8, count + 1);
    defer r.alloc.free(lines);
    var itr = std.mem.split(u8, src, "\n");
    var i: usize = 0;
    while (itr.next()) |line| {
        lines[i] = try std.fmt.allocPrint(r.alloc, "{}\n", .{span(HTML.text(line))});
        i += 1;
    }
    defer for (lines) |line| r.alloc.free(line);
    // TODO better API to avoid join
    var joined = try std.mem.join(r.alloc, "", lines);
    defer r.alloc.free(joined);

    tmpl.addVar("code", joined) catch return Error.Unknown;
    //var page = tmpl.build(r.alloc) catch unreachable;
    var page = std.fmt.allocPrint(r.alloc, "{}", .{tmpl}) catch unreachable;
    sendMsg(r, page) catch |e| {
        std.log.err("Unexpected error while responding [{}]\n", .{e});
    };
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
                if (eql(uri[0..ep.name.len], ep.name)) return route;
            },
        }
    }
    return notfound;
}
