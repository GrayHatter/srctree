alloc: Allocator,
repo: ?*const Repo = null,
cwd: ?std.fs.Dir = null,

const Agent = @This();

const DEBUG_GIT_ACTIONS = false;

pub fn pullUpstream(self: Agent, branch: []const u8) !bool {
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

pub fn pushDownstream(self: Agent) !bool {
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
    const child = try self.execCustom(&[_][]const u8{
        "git",
        "clone",
        "--bare",
        "--origin",
        "upstream",
        uri,
        local_dir,
    });
    if (child.stderr.len > 0) {
        std.debug.print("git Agent error\nstderr: {s}\n", .{child.stderr});
        if (std.mem.indexOf(u8, child.stderr, "does not exist")) |_| {
            return error.RemoteRepoUnreachable;
        } else {
            return error.UnexpectedGitError;
        }
    }
    defer self.alloc.free(child.stderr);

    if (DEBUG_GIT_ACTIONS) std.debug.print(
        "git action\n{s}\n'''\n{s} \n''' \n{s} \n''' \ngit agent\n{any}\n",
        .{ uri, child.stdout, child.stderr, self.cwd },
    );

    return child.stdout;
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
        "--histogram",
        "--diff-merges=1",
        "-p",
        sha,
    });
}

pub fn formatPatch(self: Agent, sha: []const u8) ![]u8 {
    return try self.exec(&[_][]const u8{
        "git",
        "format-patch",
        "--histogram",
        "--stdout",
        sha,
    });
}

pub fn checkPatch(self: Agent, patch: []const u8) !?[]u8 {
    const res = try self.execStdin(&.{
        "git",
        "apply",
        "--check",
        "--verbose",
        "--",
    }, patch);

    if (res.term.Exited == 0) return null;
    std.debug.print("git apply error {}\n", .{res.term.Exited});
    std.debug.print("stderr {s}", .{res.stderr});
    std.debug.print("stdout {s}", .{res.stdout});
    return error.DoesNotApply;
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

fn execStdin(self: Agent, argv: []const []const u8, stdin: []const u8) !std.process.Child.RunResult {
    std.debug.assert(std.mem.eql(u8, argv[0], "git"));
    const cwd = if (self.cwd != null and self.cwd.?.fd != std.fs.cwd().fd) self.cwd else null;
    var child = std.process.Child.init(argv, self.alloc);

    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd_dir = cwd;

    var stdout = std.ArrayListUnmanaged(u8){};
    var stderr = std.ArrayListUnmanaged(u8){};
    errdefer {
        stdout.deinit(self.alloc);
        stderr.deinit(self.alloc);
    }

    try child.spawn();
    if (child.stdin) |cstdin| {
        try cstdin.writeAll(stdin);
        cstdin.close();
        child.stdin = null;
    }

    child.collectOutput(self.alloc, &stdout, &stderr, 0x1fffff) catch |err| {
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

    const res = std.process.Child.RunResult{
        .term = try child.wait(),
        .stdout = try stdout.toOwnedSlice(self.alloc),
        .stderr = try stderr.toOwnedSlice(self.alloc),
    };

    return res;
}

fn execCustom(self: Agent, argv: []const []const u8) !std.process.Child.RunResult {
    std.debug.assert(std.mem.eql(u8, argv[0], "git"));
    const cwd = if (self.cwd != null and self.cwd.?.fd != std.fs.cwd().fd) self.cwd else null;
    const child = std.process.Child.run(.{
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
    if (child.stderr.len > 0) {
        std.debug.print("git Agent error\nstderr: {s}\n", .{child.stderr});
    }
    defer self.alloc.free(child.stderr);

    if (DEBUG_GIT_ACTIONS) std.debug.print(
        \\git action
        \\{s}
        \\'''
        \\{s}
        \\'''
        \\{s}
        \\'''
        \\
        \\git agent
        \\{any}
        \\
    , .{ argv[1], child.stdout, child.stderr, self.cwd });
    return child.stdout;
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const Git = @import("../git.zig");
const Repo = Git.Repo;
const Tree = Git.Tree;
