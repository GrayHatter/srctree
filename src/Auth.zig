auth: verse.Auth,
alloc: Allocator,
io: Io,

const Auth = @This();

pub fn init(a: Allocator, io: Io) Auth {
    return .{
        .auth = .{
            .vtable = &.{
                .valid = valid,
                .lookupUser = lookupUser,
                .authenticate = verse.Auth.MTLS.authenticate,
                .createSession = null,
                .getUserCookie = null,
                .getUserToken = null,
            },
        },
        .alloc = a,
        .io = io,
    };
}

pub fn raze(_: Auth) void {}

pub fn valid(ptr: *const verse.Auth, u: *const verse.Auth.User) bool {
    const auth: *const Auth = @fieldParentPtr("auth", ptr);
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

pub fn lookupUser(ptr: *const verse.Auth, user_id: []const u8) !verse.Auth.User {
    log.debug("lookup user {s}", .{user_id});
    const auth: *const Auth = @fieldParentPtr("auth", ptr);
    const user: *types.User = auth.alloc.create(types.User) catch @panic("OOM");
    user.* = types.User.findMTLSFingerprint(user_id, auth.alloc, auth.io) catch |err| {
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
const Io = std.Io;
