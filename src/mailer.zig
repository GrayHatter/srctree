const std = @import("std");

fn usage() !void {
    std.debug.print("TODO write usage/help text\n", .{});
}

fn receive() !void {
    var stdin = std.io.getStdIn();
    const in_reader = stdin.reader();
    const reader = in_reader.any();
    const a = std.heap.page_allocator;
    const message = reader.readAllAlloc(a, 0xA00000) catch |err| {
        switch (err) {
            else => std.log.err("something went wrong {}", .{err}),
        }
        std.process.exit(2);
    };
    _ = message;
}

pub fn main() !void {
    var args = std.process.args();
    var config_filename: []const u8 = "./mailer.ini";
    _ = args.next() orelse {
        std.log.err("argv is invalid", .{});
        std.process.exit(10);
    };
    const action = args.next() orelse {
        std.log.err("no action was supplied", .{});
        std.process.exit(11);
    };
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "-h")) {
            // TODO stdout instead
            try usage();
            std.process.exit(0);
        } else if (std.mem.startsWith(u8, arg, "-c")) {
            if (args.next()) |arg_conf| {
                config_filename = arg_conf;
            } else {
                std.log.err("no config file given following -c", .{});
                std.process.exit(1);
            }
        }
    }

    if (std.mem.eql(u8, action, "send")) {
        std.log.err("send not implemented", .{});
        std.process.exit(1);
    } else if (std.mem.eql(u8, action, "receive")) {
        std.log.err("receive not implemented (but good luck!)", .{});
        try receive();
        std.process.exit(1);
    } else if (std.mem.eql(u8, action, "-h")) {
        try usage();
        std.process.exit(0);
    }
}
