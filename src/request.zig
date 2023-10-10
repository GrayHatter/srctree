const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Request = @This();
const zWSGIRequest = @import("zwsgi.zig").zWSGIRequest;

const RawRequests = union {
    zwsgi: zWSGIRequest,
};

const Pair = struct {
    name: []u8,
    val: []u8,
};

const HeaderList = std.ArrayList(Pair);

/// TODO this is unstable and likely to be removed
raw_request: RawRequests,

//headers: HeaderList,
uri: []const u8,

pub fn build(raw_req: anytype) Request {
    switch (@TypeOf(raw_req)) {
        zWSGIRequest => {
            var uri: []const u8 = "/";
            for (raw_req.vars) |v| {
                if (std.mem.eql(u8, v.key, "REQUEST_URI")) {
                    uri = v.val;
                    break;
                }
            }
            return .{
                .raw_request = .{ .zwsgi = raw_req },
                .uri = uri,
            };
        },
        else => @compileError("rawish isn't a support request type"),
    }
    unreachable;
}
