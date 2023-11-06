const std = @import("std");
const Allocator = std.mem.Allocator;
const zWSGIRequest = @import("zwsgi.zig").zWSGIRequest;
const Auth = @import("auth.zig");

pub const Request = @This();

pub const RawRequests = union(enum) {
    zwsgi: zWSGIRequest,
    http: std.http.Server.Response,
};

const Pair = struct {
    name: []const u8,
    val: []const u8,
};

pub const HeaderList = std.ArrayList(Pair);

/// TODO this is unstable and likely to be removed
raw_request: RawRequests,

headers: HeaderList,
uri: []const u8,
auth: Auth,

pub fn init(a: Allocator, raw_req: anytype) !Request {
    switch (@TypeOf(raw_req)) {
        zWSGIRequest => {
            var req = Request{
                .raw_request = .{ .zwsgi = raw_req },
                .headers = HeaderList.init(a),
                .uri = undefined,
                .auth = undefined,
            };
            for (raw_req.vars) |v| {
                try addHeader(&req.headers, v.key, v.val);
                if (std.mem.eql(u8, v.key, "REQUEST_URI")) {
                    req.uri = v.val;
                }
            }
            req.auth = Auth.init(&req.headers);
            return req;
        },
        std.http.Server.Response => {
            var req = Request{
                .raw_request = .{ .http = raw_req },
                .headers = HeaderList.init(a),
                .uri = undefined,
                .auth = undefined,
            };
            req.uri = raw_req.request.target;
            //for (raw_req.request.headers) |v| {
            //    try addHeader(&req.headers, v.key, v.val);
            //    if (std.mem.eql(u8, v.key, "REQUEST_URI")) {
            //        req.uri = v.val;
            //    }
            //}
            //req.auth = Auth.init(&req.headers);
            return req;
        },
        else => @compileError("rawish isn't a support request type"),
    }
    @compileError("unreachable");
}

fn addHeader(h: *HeaderList, name: []const u8, val: []const u8) !void {
    try h.append(.{ .name = name, .val = val });
}
