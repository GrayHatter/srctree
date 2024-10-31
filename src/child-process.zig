const std = @import("std");

const ChildProc = @This();

const BUFSIZE = 0xffffff;

const poll_err_mask = std.os.POLL.ERR | std.os.POLL.NVAL | std.os.POLL.HUP;

child: std.ChildProcess,
std: struct {
    out: []u8,
    err: []u8,
},
poll_fds: [2]std.os.pollfd,

pub fn init(
    a: std.mem.Allocator,
    cmd: []const []const u8,
    opts: struct {
        map: ?*std.process.EnvMap = null,
        spawn_now: bool = false,
    },
) !ChildProc {
    var child = std.ChildProcess.init(cmd, a);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = opts.map;
    child.expand_arg0 = .no_expand;

    var self = ChildProc{
        .child = child,
        .std = .{
            .out = try a.alloc(u8, BUFSIZE),
            .err = try a.alloc(u8, BUFSIZE),
        },
        .poll_fds = .{
            .{
                .fd = child.stdout.?.handle,
                .events = std.os.POLL.IN,
                .revents = undefined,
            },
            .{
                .fd = child.stderr.?.handle,
                .events = std.os.POLL.IN,
                .revents = undefined,
            },
        },
    };

    if (opts.spawn_now) try self.spawn();
    return self;
}

pub fn spawn(self: *ChildProc) !void {
    try self.child.spawn();
}

pub fn stdin(self: *ChildProc, data: []const u8, more: bool) !usize {
    const out = try std.os.write(self.child.stdin.?.handle, data);
    if (!more) {
        std.os.close(self.child.stdin.?.handle);
        self.child.stdin = null;
    }
    return out;
}

pub fn stdpoll(_: *ChildProc, fd: *std.os.pollfd, buf: []u8) ![]const u8 {
    while (true) {
        const poll: []std.os.pollfd = &[_]std.os.pollfd{fd};
        const events_len = std.os.poll(poll, std.math.maxInt(i32)) catch unreachable;
        if (events_len == 0) continue;
        if (fd.revents & std.os.POLL.IN != 0) {
            const amt = std.os.read(fd.fd, buf) catch unreachable;
            if (amt == 0) break;
        } else if (fd.revents & poll_err_mask != 0) {
            break;
        }
    }
}

pub fn stdout(self: *ChildProc) ![]const u8 {
    return self.stdpoll(self.poll_fds[0], self.std.out);
}

pub fn stderr(self: *ChildProc) ![]const u8 {
    return self.stdpoll(self.poll_fds[1], self.std.err);
}

pub fn raze(self: *ChildProc) void {
    _ = self.child.wait() catch unreachable;
}
