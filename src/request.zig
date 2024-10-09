const std = @import("std");
const Allocator = std.mem.Allocator;
const zWSGIRequest = @import("zwsgi.zig").zWSGIRequest;
const Auth = @import("auth.zig");

pub const Request = @This();

pub const RawRequests = union(enum) {
    zwsgi: zWSGIRequest,
    http: std.http.Server.Request,
};

const Pair = struct {
    name: []const u8,
    val: []const u8,
};

pub const HeaderList = std.ArrayList(Pair);

pub const Methods = enum(u8) {
    GET = 1,
    HEAD = 2,
    POST = 4,
    PUT = 8,
    DELETE = 16,
    CONNECT = 32,
    OPTIONS = 64,
    TRACE = 128,

    pub fn fromStr(s: []const u8) !Methods {
        inline for (std.meta.fields(Methods)) |field| {
            if (std.mem.startsWith(u8, s, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return error.UnknownMethod;
    }
};

/// TODO this is unstable and likely to be removed
raw_request: RawRequests,

headers: HeaderList,
uri: []const u8,
method: Methods,
auth: Auth,

pub fn init(a: Allocator, raw_req: anytype) !Request {
    switch (@TypeOf(raw_req)) {
        zWSGIRequest => {
            var req = Request{
                .raw_request = .{ .zwsgi = raw_req },
                .headers = HeaderList.init(a),
                .uri = undefined,
                .method = Methods.GET,
                .auth = undefined,
            };
            for (raw_req.vars) |v| {
                try addHeader(&req.headers, v.key, v.val);
                if (std.mem.eql(u8, v.key, "PATH_INFO")) {
                    req.uri = v.val;
                }
                if (std.mem.eql(u8, v.key, "REQUEST_METHOD")) {
                    req.method = Methods.fromStr(v.val) catch Methods.GET;
                }
            }
            req.auth = Auth.init(req.headers);
            return req;
        },
        std.http.Server.Request => {
            var req = Request{
                .raw_request = .{ .http = raw_req },
                .headers = HeaderList.init(a),
                .uri = undefined,
                .method = Methods.GET,
                .auth = undefined,
            };
            req.auth = Auth.init(req.headers);
            return req;
        },
        else => @compileError("rawish of " ++ @typeName(raw_req) ++ " isn't a support request type"),
    }
    @compileError("unreachable");
}

fn addHeader(h: *HeaderList, name: []const u8, val: []const u8) !void {
    try h.append(.{ .name = name, .val = val });
}

pub fn getHeader(self: Request, key: []const u8) ?[]const u8 {
    for (self.headers.items) |itm| {
        if (std.mem.eql(u8, itm.name, key)) {
            return itm.val;
        }
    } else {
        return null;
    }
}
