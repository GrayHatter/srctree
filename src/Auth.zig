const std = @import("std");

const Allocator = std.mem.Allocator;

const Request = @import("request.zig");
const HeaderList = Request.HeaderList;
const User = @import("types.zig").User;

const Auth = @This();

pub const MethodType = enum {
    none,
    unknown,
    invalid,
    mtls,
};

const Reason = enum {
    because_i_said_so,
};

const MTLSPayload = struct {
    status: []const u8,
    fingerprint: []const u8,
    cert: []const u8,

    pub fn valid(m: MTLSPayload) bool {
        var buffer: [0xffff]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const a = fba.allocator();
        const user = User.findMTLSFingerprint(a, m.fingerprint) catch |err| {
            std.debug.print("Auth failure {}\n", .{err});
            return false;
        };
        const time = std.time.timestamp();
        if (user.not_before <= time and user.not_after >= time) {
            return true;
        } else {
            return false;
        }
    }
};

const Method = union(MethodType) {
    none: void,
    unknown: void,
    invalid: Reason,
    mtls: MTLSPayload,
};

method: Method,

pub fn init(h: HeaderList) Auth {
    var status: ?[]const u8 = null;
    var fingerprint: ?[]const u8 = null;
    var cert: ?[]const u8 = null;
    for (h.items) |header| {
        if (std.mem.eql(u8, header.name, "MTLS_ENABLED")) {
            status = header.val;
        } else if (std.mem.eql(u8, header.name, "MTLS_FINGERPRINT")) {
            fingerprint = header.val;
        } else if (std.mem.eql(u8, header.name, "MTLS_CERT")) {
            cert = header.val;
        }
    }

    if (status) |s| {
        if (fingerprint) |f| {
            if (cert) |c| {
                return .{
                    .method = .{ .mtls = .{
                        .status = s,
                        .fingerprint = f,
                        .cert = c,
                    } },
                };
            }
        }
    }

    return .{
        .method = .none,
    };
}

pub fn valid(auth: Auth) bool {
    return switch (auth.method) {
        .mtls => |m| m.valid(),
        else => false,
    };
}

pub fn validOrError(auth: Auth) !void {
    if (!auth.valid()) return error.Unauthenticated;
}

pub fn currentUser(auth: Auth, a: Allocator) !User {
    switch (auth.method) {
        .mtls => |m| {
            return try User.findMTLSFingerprint(a, m.fingerprint);
        },
        else => return error.NotImplemted,
    }
}
