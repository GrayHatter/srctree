const std = @import("std");
const Allocator = std.mem.Allocator;
const StreamServer = std.net.StreamServer;
const Request = @import("request.zig");
const Response = @import("response.zig");
const Router = @import("routes.zig");

const uProtoHeader = packed struct {
    mod1: u8 = 0,
    size: u16 = 0,
    mod2: u8 = 0,
};

const uWSGIVar = struct {
    key: []const u8,
    val: []const u8,

    pub fn read(_: []u8) uWSGIVar {
        return uWSGIVar{ .key = "", .val = "" };
    }

    pub fn format(self: uWSGIVar, comptime _: []const u8, _: std.fmt.FormatOptions, out: anytype) !void {
        try std.fmt.format(out, "\"{s}\" = \"{s}\"", .{
            self.key,
            if (self.val.len > 0) self.val else "[Empty]",
        });
    }
};

pub const zWSGIRequest = struct {
    header: uProtoHeader,
    vars: []uWSGIVar,
    body: ?[]u8 = null,
};

fn readU16(b: *const [2]u8) u16 {
    std.debug.assert(b.len >= 2);
    return @as(u16, @bitCast(b[0..2].*));
}

test "readu16" {
    const buffer = [2]u8{ 238, 1 };
    const size: u16 = 494;
    try std.testing.expectEqual(size, readU16(&buffer));
}

fn readVars(a: Allocator, b: []const u8) ![]uWSGIVar {
    var list = std.ArrayList(uWSGIVar).init(a);
    var buf = b;
    while (buf.len > 0) {
        var keysize = readU16(buf[0..2]);
        buf = buf[2..];
        const key = try a.dupe(u8, buf[0..keysize]);
        buf = buf[keysize..];

        var valsize = readU16(buf[0..2]);
        buf = buf[2..];
        const val = try a.dupe(u8, if (valsize == 0) "" else buf[0..valsize]);
        buf = buf[valsize..];

        try list.append(uWSGIVar{
            .key = key,
            .val = val,
        });
        std.log.info("VAR {} ", .{list.items[list.items.len - 1]});
    }
    return try list.toOwnedSlice();
}

fn readHeader(a: std.mem.Allocator, acpt: std.net.StreamServer.Connection) !Request {
    var uwsgi_header = uProtoHeader{};
    var ptr: [*]u8 = @ptrCast(&uwsgi_header);
    _ = try acpt.stream.read(@alignCast(ptr[0..4]));

    std.log.info("header {any}", .{@as([]const u8, ptr[0..4])});
    std.log.info("header {}", .{uwsgi_header});

    var buf: []u8 = try a.alloc(u8, uwsgi_header.size);
    const read = try acpt.stream.read(buf);
    if (read != uwsgi_header.size) {
        std.log.err("unexpected read size {} {}", .{ read, uwsgi_header.size });
    }

    const vars = try readVars(a, buf);
    for (vars) |v| {
        if (std.mem.eql(u8, v.key, "HTTP_CONTENT_LENGTH")) {
            const post_size = try std.fmt.parseInt(usize, v.val, 10);
            var post_buf: []u8 = try a.alloc(u8, post_size);
            _ = try acpt.stream.read(post_buf);
            std.log.info("post data \"{s}\" {{{any}}}", .{ post_buf, post_buf });
        }
    }

    return try Request.init(
        a,
        zWSGIRequest{ .header = uwsgi_header, .vars = vars },
    );
}

pub fn serve(a: Allocator, streamsrv: *StreamServer) !void {
    while (true) {
        var acpt = try streamsrv.accept();
        const request = try readHeader(a, acpt);
        var response = Response.init(a, acpt.stream, &request);

        var endpoint = Router.route(response.request.uri);
        try endpoint(&response, "");
        if (response.phase != .closed) try response.finish();
        acpt.stream.close();
    }
}
