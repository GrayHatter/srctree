alloc: Allocator,

const Auth = @This();

pub fn init(a: Allocator) Auth {
    return .{ .alloc = a };
}

pub fn raze(_: Auth) void {}

pub fn provider(self: *Auth) verse.auth.Provider {
    return .{
        .ctx = self,
        .vtable = .{
            .authenticate = null,
            .valid = valid,
            .create_session = null,
            .get_cookie = null,
            .lookup_user = lookupUser,
        },
    };
}

pub fn valid(ptr: *const anyopaque, u: *const verse.auth.User) bool {
    const auth: *const Auth = @ptrCast(@alignCast(ptr));
    _ = &auth;
    if (u.username != null and
        u.unique_id != null and
        u.user_ptr != null and
        u.authenticated)
    {
        return true;
    }
    return false;
}

pub fn lookupUser(ptr: *anyopaque, user_id: []const u8) !verse.auth.User {
    log.debug("lookup user {s}", .{user_id});
    const auth: *Auth = @ptrCast(@alignCast(ptr));
    const user: *types.User = auth.alloc.create(types.User) catch @panic("OOM");
    user.* = types.User.findMTLSFingerprint(user_id) catch |err| {
        std.debug.print("mtls lookup error {}\n", .{err});
        return error.UnknownUser;
    };

    return .{
        .user_ptr = user,
        .unique_id = auth.alloc.dupe(u8, user_id) catch @panic("OOM"),
        .username = user.username.slice(),
    };
}

test {
    std.testing.refAllDecls(Auth);
}

const types = @import("types.zig");
const verse = @import("verse");
const std = @import("std");
const log = std.log.scoped(.srctree_auth);
const Allocator = std.mem.Allocator;
