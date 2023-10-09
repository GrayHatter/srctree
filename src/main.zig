const std = @import("std");
const Server = std.http.Server;
const HTML = @import("html.zig");
const Template = @import("template.zig");
const Route = @import("route.zig");
const Endpoint = @import("endpoint.zig");
const EndpointErr = Endpoint.Error;
const HTTP = @import("http.zig");
const zWSGI = @import("zwsgi.zig");

const HOST = "127.0.0.1";
const PORT = 2000;

test "main" {
    std.testing.refAllDecls(@This());
    _ = HTML.html(&[0]HTML.Element{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 12 }){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    Template.init(a);
    defer Template.raze();

    var usock = std.net.StreamServer.init(.{});
    const FILE = "./srctree.sock";

    var cwd = std.fs.cwd();
    if (cwd.access(FILE, .{})) {
        try cwd.deleteFile(FILE);
    } else |_| {}

    const uaddr = try std.net.Address.initUnix(FILE);
    try usock.listen(uaddr);
    std.log.info("Unix server listening\n", .{});

    var path = try std.fs.cwd().realpathAlloc(a, FILE);
    var zpath = try a.dupeZ(u8, path);
    a.free(path);
    var mode = std.os.linux.chmod(zpath, 0o777);
    if (false) std.debug.print("mode {o}\n", .{mode});
    defer a.free(zpath);

    try zWSGI.serve(a, &usock);
    usock.close();

    var srv = Server.init(a, .{ .reuse_address = true });

    const addr = std.net.Address.parseIp(HOST, PORT) catch unreachable;
    try srv.listen(addr);
    std.log.info("Server listening\n", .{});

    HTTP.serve(a, &srv) catch {
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        std.os.exit(1);
    };
}

test "simple test" {
    //const a = std.testing.allocator;

    try std.testing.expect(true);
}
