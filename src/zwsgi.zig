const std = @import("std");

const Allocator = std.mem.Allocator;
const StreamServer = std.net.StreamServer;

const Request = @import("request.zig");
const Response = @import("response.zig");
const Router = @import("routes.zig");
const HttpPostData = @import("http-post-data.zig");

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
    acpt: std.net.StreamServer.Connection,
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
    }
    return try list.toOwnedSlice();
}

const dump_vars = false;

fn readHeader(a: Allocator, acpt: std.net.StreamServer.Connection) !Request {
    var uwsgi_header = uProtoHeader{};
    var ptr: [*]u8 = @ptrCast(&uwsgi_header);
    _ = try acpt.stream.read(@alignCast(ptr[0..4]));

    var buf: []u8 = try a.alloc(u8, uwsgi_header.size);
    const read = try acpt.stream.read(buf);
    if (read != uwsgi_header.size) {
        std.log.err("unexpected read size {} {}", .{ read, uwsgi_header.size });
    }

    const vars = try readVars(a, buf);
    for (vars) |v| {
        if (dump_vars) std.log.info("{}", .{v});
    }

    return try Request.init(
        a,
        zWSGIRequest{
            .header = uwsgi_header,
            .acpt = acpt,
            .vars = vars,
        },
    );
}

fn find(list: []uWSGIVar, search: []const u8) ?[]const u8 {
    for (list) |each| {
        if (std.mem.eql(u8, each.key, search)) return each.val;
    }
    return null;
}

fn findOr(list: []uWSGIVar, search: []const u8) []const u8 {
    return find(list, search) orelse "[missing]";
}

pub fn serve(a: Allocator, streamsrv: *StreamServer) !void {
    while (true) {
        var acpt = try streamsrv.accept();
        var request = try readHeader(a, acpt);

        std.log.info("zWSGI: {s} - {s}: {s} -- \"{s}\"", .{
            findOr(request.raw_request.zwsgi.vars, "REMOTE_ADDR"),
            findOr(request.raw_request.zwsgi.vars, "REQUEST_METHOD"),
            findOr(request.raw_request.zwsgi.vars, "REQUEST_URI"),
            findOr(request.raw_request.zwsgi.vars, "HTTP_USER_AGENT"),
        });

        var arena = std.heap.ArenaAllocator.init(a);
        var alloc = arena.allocator();
        var response = Response.init(alloc, &request);

        if (find(request.raw_request.zwsgi.vars, "HTTP_CONTENT_LENGTH")) |h_len| {
            const h_type = findOr(request.raw_request.zwsgi.vars, "HTTP_CONTENT_TYPE");

            const post_size = try std.fmt.parseInt(usize, h_len, 10);
            var post_body = try HttpPostData.readBody(a, acpt, post_size, h_type);
            std.log.info("post data \"{s}\" {{{any}}}", .{ post_body.rawdata, post_body.rawdata });

            for (post_body.items) |itm| {
                std.log.info("{}", .{itm});
            }
        }

        Router.baseRouter(&response, response.request.uri) catch |err| {
            switch (err) {
                error.Unknown => return err,
                error.OutOfMemory,
                error.ReqResInvalid,
                error.AndExit,
                error.Unrouteable,
                error.InvalidURI,
                => {},
                error.Abusive => {
                    std.debug.print("Abusive {}\n", .{request});
                    for (request.raw_request.zwsgi.vars) |vars| {
                        std.debug.print("Abusive var '{s}' => '''{s}'''\n", .{ vars.key, vars.val });
                    }
                },
            }
        };

        if (response.phase != .closed) try response.finish();
        arena.deinit();
        acpt.stream.close();
    }
}
