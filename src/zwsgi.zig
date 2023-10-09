const std = @import("std");
const Allocator = std.mem.Allocator;
const StreamServer = std.net.StreamServer;
const Template = @import("template.zig");

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
};

fn uwsgiHeader(a: std.mem.Allocator, acpt: std.net.StreamServer.Connection) ![][]u8 {
    var list = std.ArrayList([]u8).init(a);

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

    while (buf.len > 0) {
        var size = @as(u16, @bitCast(buf[0..2].*));
        buf = buf[2..];
        const key = buf[0..size];
        std.log.info("VAR {s} ({})[{any}] ", .{ key, size, key });
        buf = buf[size..];
        size = @as(u16, @bitCast(buf[0..2].*));
        buf = buf[2..];
        if (size > 0) {
            const val = buf[0..size];
            std.log.info("VAR {s} ({})[{any}] ", .{ val, size, val });
            buf = buf[size..];
        } else {
            std.log.info("VAR [empty value] ", .{});
        }
    }

    return list.toOwnedSlice();
}

pub fn serve(a: Allocator, streamsrv: *StreamServer) !void {
    while (true) {
        var acpt = try streamsrv.accept();
        _ = try uwsgiHeader(a, acpt);
        _ = try acpt.stream.write(Template.builtin[0].blob);
        acpt.stream.close();
    }
}
