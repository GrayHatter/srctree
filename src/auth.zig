const std = @import("std");

const Allocator = std.mem.Allocator;

const Request = @import("request.zig");
const HeaderList = Request.HeaderList;
const Users = @import("types/users.zig");

const Auth = @This();

pub const Method = enum {
    none,
    unknown,
    invalid,
    mtls,

    pub fn valid(m: Method) bool {
        return switch (m) {
            .mtls => true,
            else => false,
        };
    }
};

const Reason = enum {
    because_i_said_so,
};

const MTLSPayload = struct {
    status: []const u8,
    fingerprint: []const u8,
    cert: []const u8,
};

const Payload = union(Method) {
    none: void,
    unknown: void,
    invalid: Reason,
    mtls: MTLSPayload,
};

method: Method,
payload: Payload,

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
                    .method = .mtls,
                    .payload = .{
                        .mtls = .{
                            .status = s,
                            .fingerprint = f,
                            .cert = c,
                        },
                    },
                };
            }
        }
    }

    return .{
        .method = .none,
        .payload = .unknown,
    };
}

pub fn valid(auth: Auth) bool {
    return auth.method.valid();
}

pub fn validOrError(auth: Auth) !void {
    if (!auth.valid()) return error.Unauthenticated;
}

pub fn user(auth: Auth, a: Allocator) !Users.User {
    switch (auth.method) {
        .mtls => {
            return try Users.findMTLSFingerprint(a, auth.payload.mtls.fingerprint);
        },
        else => return error.NotImplemted,
    }
}
