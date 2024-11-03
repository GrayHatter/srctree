const std = @import("std");
const Allocator = std.mem.Allocator;

const Git = @import("../git.zig");
const Repo = Git.Repo;
const Tree = Git.Tree;

pub const Agent = @This();

const DEBUG_GIT_ACTIONS = false;

alloc: Allocator,
repo: ?*const Repo = null,
cwd: ?std.fs.Dir = null,

pub fn updateUpstream(self: Agent, branch: []const u8) !bool {
    const fetch = try self.exec(&[_][]const u8{
        "git",
        "fetch",
        "upstream",
        "-q",
    });
    if (fetch.len > 0) std.debug.print("fetch {s}\n", .{fetch});
    self.alloc.free(fetch);

    var buf: [512]u8 = undefined;
    const up_branch = try std.fmt.bufPrint(&buf, "upstream/{s}", .{branch});
    const pull = try self.execCustom(&[_][]const u8{
        "git",
        "merge-base",
        "--is-ancestor",
        "HEAD",
        up_branch,
    });
    defer self.alloc.free(pull.stdout);
    defer self.alloc.free(pull.stderr);

    if (pull.term.Exited == 0) {
        const move = try self.exec(&[_][]const u8{
            "git",
            "fetch",
            "upstream",
            "*:*",
            "-q",
        });
        self.alloc.free(move);
        return true;
    } else {
        std.debug.print("refusing to move head non-ancestor\n", .{});
        return false;
    }
}

pub fn updateDownstream(self: Agent) !bool {
    const push = try self.exec(&[_][]const u8{
        "git",
        "push",
        "downstream",
        "*:*",
        "--porcelain",
    });
    std.debug.print("pushing downstream ->\n{s}\n", .{push});
    self.alloc.free(push);
    return true;
}

pub fn forkRemote(self: Agent, uri: []const u8, local_dir: []const u8) ![]u8 {
    return try self.exec(&[_][]const u8{
        "git",
        "clone",
        "--bare",
        "--origin",
        "upstream",
        uri,
        local_dir,
    });
}

pub fn initRepo(self: Agent, dir: []const u8, opt: struct { bare: bool = true }) ![]u8 {
    return try self.exec(&[_][]const u8{
        "git",
        "init",
        if (opt.bare) "--bare" else "",
        dir,
    });
}

pub fn show(self: Agent, sha: []const u8) ![]u8 {
    return try self.exec(&[_][]const u8{
        "git",
        "show",
        "--diff-merges=1",
        "-p",
        sha,
    });
}

pub fn blame(self: Agent, name: []const u8) ![]u8 {
    std.debug.print("{s}\n", .{name});
    return try self.exec(&[_][]const u8{
        "git",
        "blame",
        "--porcelain",
        name,
    });
}

fn execCustom(self: Agent, argv: []const []const u8) !std.ChildProcess.RunResult {
    std.debug.assert(std.mem.eql(u8, argv[0], "git"));
    const cwd = if (self.cwd != null and self.cwd.?.fd != std.fs.cwd().fd) self.cwd else null;
    const child = std.ChildProcess.run(.{
        .cwd_dir = cwd,
        .allocator = self.alloc,
        .argv = argv,
        .max_output_bytes = 0x1FFFFF,
    }) catch |err| {
        const errstr =
            \\git agent error:
            \\error :: {}
            \\argv :: 
        ;
        std.debug.print(errstr, .{err});
        for (argv) |arg| std.debug.print("{s} ", .{arg});
        std.debug.print("\n", .{});
        return err;
    };
    return child;
}

fn exec(self: Agent, argv: []const []const u8) ![]u8 {
    const child = try self.execCustom(argv);
    if (child.stderr.len > 0) std.debug.print("git Agent error\nstderr {s}\n", .{child.stderr});
    self.alloc.free(child.stderr);

    if (DEBUG_GIT_ACTIONS) std.debug.print(
        \\git action
        \\{s}
        \\'''
        \\{s}
        \\'''
        \\
    , .{ argv[1], child.stdout });
    return child.stdout;
}
