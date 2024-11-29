const std = @import("std");

const Allocator = std.mem.Allocator;
const Server = std.net.Server;

const Context = @import("context.zig");
const Request = @import("request.zig");
const Response = @import("response.zig");
const Router = @import("routes.zig");
const RequestData = @import("request_data.zig");
const Config = @import("ini.zig").Config;

const ZWSGI = @This();

alloc: Allocator,
config: Config,
routefn: RouterFn,
buildfn: BuildFn,
runmode: RunMode = .unix,

pub const RouterFn = *const fn (*Context) Router.Callable;
// TODO provide default for this?
pub const BuildFn = *const fn (*Context, Router.Callable) Router.Error!void;

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
    acpt: Server.Connection,
    vars: []uWSGIVar,
    body: ?[]u8 = null,
};

pub fn init(a: Allocator, config: Config, route_fn: RouterFn, build_fn: BuildFn) ZWSGI {
    return .{
        .alloc = a,
        .config = config,
        .routefn = route_fn,
        .buildfn = build_fn,
    };
}

const HOST = "127.0.0.1";
const PORT = 2000;
const FILE = "./srctree.sock";

fn serveUnix(zwsgi: *ZWSGI) !void {
    var cwd = std.fs.cwd();
    if (cwd.access(FILE, .{})) {
        try cwd.deleteFile(FILE);
    } else |_| {}

    const uaddr = try std.net.Address.initUnix(FILE);
    var server = try uaddr.listen(.{});
    defer server.deinit();

    const path = try std.fs.cwd().realpathAlloc(zwsgi.alloc, FILE);
    defer zwsgi.alloc.free(path);
    const zpath = try zwsgi.alloc.dupeZ(u8, path);
    defer zwsgi.alloc.free(zpath);
    const mode = std.os.linux.chmod(zpath, 0o777);
    if (false) std.debug.print("mode {o}\n", .{mode});
    std.debug.print("Unix server listening\n", .{});

    while (true) {
        var acpt = try server.accept();
        defer acpt.stream.close();
        var timer = try std.time.Timer.start();

        var arena = std.heap.ArenaAllocator.init(zwsgi.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var ctx = try zwsgi.buildContextuWSGI(a, &acpt);

        defer {
            std.log.err("zWSGI: [{d:.3}] {s} - {s}: {s} -- \"{s}\"", .{
                @as(f64, @floatFromInt(timer.lap())) / 1000000.0,
                findOr(ctx.request.raw_request.zwsgi.vars, "REMOTE_ADDR"),
                findOr(ctx.request.raw_request.zwsgi.vars, "REQUEST_METHOD"),
                findOr(ctx.request.raw_request.zwsgi.vars, "REQUEST_URI"),
                findOr(ctx.request.raw_request.zwsgi.vars, "HTTP_USER_AGENT"),
            });
        }

        const callable = zwsgi.routefn(&ctx);
        zwsgi.buildfn(&ctx, callable) catch |err| {
            switch (err) {
                error.NetworkCrash => std.debug.print("client disconnect'\n", .{}),
                error.Unrouteable => {
                    std.debug.print("Unrouteable'\n", .{});
                    if (@errorReturnTrace()) |trace| {
                        std.debug.dumpStackTrace(trace.*);
                    }
                },
                error.NotImplemented,
                error.Unknown,
                error.ReqResInvalid,
                error.AndExit,
                error.NoSpaceLeft,
                => {
                    std.debug.print("Unexpected error '{}'\n", .{err});
                    return err;
                },
                error.InvalidURI => unreachable,
                error.OutOfMemory => {
                    std.debug.print("Out of memory at '{}'\n", .{arena.queryCapacity()});
                    return err;
                },
                error.Abusive,
                error.Unauthenticated,
                error.BadData,
                error.DataMissing,
                => {
                    std.debug.print("Abusive {} because {}\n", .{ ctx.request, err });
                    for (ctx.request.raw_request.zwsgi.vars) |vars| {
                        std.debug.print("Abusive var '{s}' => '''{s}'''\n", .{ vars.key, vars.val });
                    }
                    if (ctx.reqdata.post) |post_data| {
                        std.debug.print("post data => '''{s}'''\n", .{post_data.rawpost});
                    }
                },
            }
        };
    }
}

fn serveHttp(zwsgi: *ZWSGI) !void {
    const addr = std.net.Address.parseIp(HOST, PORT) catch unreachable;
    var srv = try addr.listen(.{ .reuse_address = true });
    defer srv.deinit();
    std.debug.print("HTTP Server listening\n", .{});

    const path = try std.fs.cwd().realpathAlloc(zwsgi.alloc, FILE);
    defer zwsgi.alloc.free(path);
    const zpath = try zwsgi.alloc.dupeZ(u8, path);
    defer zwsgi.alloc.free(zpath);

    const request_buffer: []u8 = try zwsgi.alloc.alloc(u8, 0xffff);
    defer zwsgi.alloc.free(request_buffer);

    while (true) {
        var conn = try srv.accept();
        defer conn.stream.close();
        std.debug.print("HTTP conn from {}\n", .{conn.address});
        var hsrv = std.http.Server.init(conn, request_buffer);
        var arena = std.heap.ArenaAllocator.init(zwsgi.alloc);
        defer arena.deinit();
        const a = arena.allocator();

        var hreq = try hsrv.receiveHead();

        var ctx = try zwsgi.buildContextHttp(a, &hreq);
        var ipbuf: [0x20]u8 = undefined;
        const ipport = try std.fmt.bufPrint(&ipbuf, "{}", .{conn.address});
        if (std.mem.indexOf(u8, ipport, ":")) |i| {
            try ctx.request.addHeader("REMOTE_ADDR", ipport[0..i]);
            try ctx.request.addHeader("REMOTE_PORT", ipport[i + 1 ..]);
        } else unreachable;

        const callable = zwsgi.routefn(&ctx);
        zwsgi.buildfn(&ctx, callable) catch |err| {
            switch (err) {
                error.NetworkCrash => std.debug.print("client disconnect'\n", .{}),
                error.Unrouteable => {
                    std.debug.print("Unrouteable'\n", .{});
                    if (@errorReturnTrace()) |trace| {
                        std.debug.dumpStackTrace(trace.*);
                    }
                },
                error.NotImplemented,
                error.Unknown,
                error.ReqResInvalid,
                error.AndExit,
                error.NoSpaceLeft,
                => {
                    std.debug.print("Unexpected error '{}'\n", .{err});
                    return err;
                },
                error.InvalidURI => unreachable,
                error.OutOfMemory => {
                    std.debug.print("Out of memory at '{}'\n", .{arena.queryCapacity()});
                    return err;
                },
                error.Abusive,
                error.Unauthenticated,
                error.BadData,
                error.DataMissing,
                => {
                    std.debug.print("Abusive {} because {}\n", .{ ctx.request, err });
                    for (ctx.request.raw_request.zwsgi.vars) |vars| {
                        std.debug.print("Abusive var '{s}' => '''{s}'''\n", .{ vars.key, vars.val });
                    }
                },
            }
        };
    }
    unreachable;
}

pub const RunMode = enum {
    unix,
    http,
    other,
    stop,
};

pub fn serve(zwsgi: *ZWSGI) !void {
    switch (zwsgi.runmode) {
        .unix => try zwsgi.serveUnix(),
        .http => try zwsgi.serveHttp(),
        else => {},
    }
}

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
        const keysize = readU16(buf[0..2]);
        buf = buf[2..];
        const key = try a.dupe(u8, buf[0..keysize]);
        buf = buf[keysize..];

        const valsize = readU16(buf[0..2]);
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

fn find(list: []uWSGIVar, search: []const u8) ?[]const u8 {
    for (list) |each| {
        if (std.mem.eql(u8, each.key, search)) return each.val;
    }
    return null;
}

fn findOr(list: []uWSGIVar, search: []const u8) []const u8 {
    return find(list, search) orelse "[missing]";
}

fn buildContext(z: ZWSGI, a: Allocator, request: *Request) !Context {
    var post_data: ?RequestData.PostData = null;
    var reqdata: RequestData = undefined;
    switch (request.raw_request) {
        .zwsgi => |zreq| {
            if (find(zreq.vars, "HTTP_CONTENT_LENGTH")) |h_len| {
                const h_type = findOr(zreq.vars, "HTTP_CONTENT_TYPE");

                const post_size = try std.fmt.parseInt(usize, h_len, 10);
                if (post_size > 0) {
                    var reader = zreq.acpt.stream.reader().any();
                    post_data = try RequestData.readBody(a, &reader, post_size, h_type);
                    if (dump_vars) std.log.info(
                        "post data \"{s}\" {{{any}}}",
                        .{ post_data.?.rawpost, post_data.?.rawpost },
                    );

                    for (post_data.?.items) |itm| {
                        if (dump_vars) std.log.info("{}", .{itm});
                    }
                }
            }

            var query: RequestData.QueryData = undefined;
            if (find(zreq.vars, "QUERY_STRING")) |qs| {
                query = try RequestData.readQuery(a, qs);
            }
            reqdata = RequestData{
                .post = post_data,
                .query = query,
            };
        },
        .http => |hreq| {
            if (hreq.head.content_length) |h_len| {
                if (h_len > 0) {
                    const h_type = hreq.head.content_type orelse "text/plain";
                    var reader = try hreq.reader();
                    post_data = try RequestData.readBody(a, &reader, h_len, h_type);
                    if (dump_vars) std.log.info(
                        "post data \"{s}\" {{{any}}}",
                        .{ post_data.?.rawpost, post_data.?.rawpost },
                    );

                    for (post_data.?.items) |itm| {
                        if (dump_vars) std.log.info("{}", .{itm});
                    }
                }
            }

            var query_data: RequestData.QueryData = undefined;
            if (std.mem.indexOf(u8, hreq.head.target, "/")) |i| {
                query_data = try RequestData.readQuery(a, hreq.head.target[i..]);
            }
            reqdata = RequestData{
                .post = post_data,
                .query = query_data,
            };
        },
    }

    const response = try Response.init(a, request);
    return Context.init(a, z.config, request.*, response, reqdata);
}

fn readHttpHeaders(a: Allocator, req: *std.http.Server.Request) !Request {
    //const vars = try readVars(a, buf);

    var itr_headers = req.iterateHeaders();
    while (itr_headers.next()) |header| {
        std.debug.print("http header => {s} -> {s}\n", .{ header.name, header.value });
        if (dump_vars) std.log.info("{}", .{header});
    }

    return try Request.init(a, req);
}

fn buildContextHttp(z: ZWSGI, a: Allocator, req: *std.http.Server.Request) !Context {
    var request = try readHttpHeaders(a, req);
    std.debug.print("http target -> {s}\n", .{request.uri});
    return z.buildContext(a, &request);
}

fn readuWSGIHeader(a: Allocator, acpt: Server.Connection) !Request {
    var uwsgi_header = uProtoHeader{};
    var ptr: [*]u8 = @ptrCast(&uwsgi_header);
    _ = try acpt.stream.read(@alignCast(ptr[0..4]));

    const buf: []u8 = try a.alloc(u8, uwsgi_header.size);
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

fn buildContextuWSGI(z: ZWSGI, a: Allocator, conn: *Server.Connection) !Context {
    var request = try readuWSGIHeader(a, conn.*);

    return z.buildContext(a, &request);
}
