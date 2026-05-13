alloc: Allocator,
repo: ?*const Repo = null,
cwd: ?Io.Dir = null,

const Agent = @This();

const DEBUG_GIT_ACTIONS = false;

pub fn pullFrom(agent: Agent, remote: []const u8, branch: []const u8, io: Io) !void {
    const fetch = try agent.exec(&.{ "git", "fetch", remote, "-q" }, io);
    if (fetch.len > 0) log.warn("fetch {s}", .{fetch});
    agent.alloc.free(fetch);

    const pull = try agent.execCustom(&.{ "git", "merge-base", "--is-ancestor", "HEAD", branch }, io);
    defer agent.alloc.free(pull.stdout);
    defer agent.alloc.free(pull.stderr);

    if (pull.term.exited == 0) {
        const move = try agent.exec(&.{ "git", "fetch", remote, "*:*", "-q" }, io);
        agent.alloc.free(move);
        return;
    }

    log.warn("refusing to move head non-ancestor {s}", .{branch});
    return error.NonAncestor;
}

pub fn pullUpstream(agent: Agent, branch_ex: []const u8, io: Io) !void {
    var buf: [512]u8 = undefined;
    const branch = std.mem.cutPrefix(u8, branch_ex, "heads/") orelse branch_ex;
    const upstream_branch = try std.fmt.bufPrint(&buf, "upstream/{s}", .{branch});
    return try agent.pullFrom("upstream", upstream_branch, io);
}

pub fn pushDownstream(agent: Agent, io: Io) !bool {
    const push = try agent.exec(&[_][]const u8{ "git", "push", "downstream", "*:*", "--porcelain" }, io);
    std.debug.print("pushing downstream ->\n{s}\n", .{push});
    agent.alloc.free(push);
    return true;
}

pub fn forkRemote(agent: Agent, uri: []const u8, local_dir: []const u8, io: Io) !void {
    const child = try agent.execCustom(
        &.{ "git", "clone", "--quiet", "--bare", "--origin", "upstream", uri, local_dir },
        io,
    );
    if (child.stderr.len > 0) {
        std.debug.print("git Agent error\nstderr: {s}\n", .{child.stderr});
        if (find(u8, child.stderr, "does not exist")) |_|
            return error.RemoteRepoUnreachable
        else
            return error.UnexpectedGitError;
    }
    defer agent.alloc.free(child.stderr);

    const cwd = agent.cwd orelse Io.Dir.cwd();
    var dir = cwd.openDir(io, local_dir, .{}) catch return error.FileSysFailed;
    defer dir.close(io);
    var file = dir.openFile(io, "config", .{ .mode = .read_write }) catch return error.FileSysFailed;
    defer file.close(io);
    var w = file.writer(io, &.{});
    w.seekTo(file.length(io) catch return error.FileSysFailed) catch return error.FileSysFailed;
    try w.interface.writeAll("    fetch = +refs/heads/*:refs/remotes/upstream/*\n");
    try w.interface.flush();

    if (DEBUG_GIT_ACTIONS) std.debug.print(
        "git action\n{s}\n'''\n{s} \n''' \n{s} \n''' \ngit agent\n{any}\n",
        .{ uri, child.stdout, child.stderr, agent.cwd },
    );
}

pub const InitEmptyOptions = struct { bare: bool = true };
pub fn initEmpty(agent: Agent, dir: []const u8, opt: InitEmptyOptions, io: Io) ![]u8 {
    if (opt.bare) {
        return try agent.exec(&.{
            "git", "init",
            "-b",     "main", // suppress the pre git v3 warning
            "--bare", dir,
        }, io);
    } else {
        return try agent.exec(&.{
            "git", "init",
            "-b", "main", // suppress the pre git v3 warning
            dir,
        }, io);
    }
}

pub fn show(agent: Agent, sha: Sha, io: Io) ![]u8 {
    return try agent.exec(
        &.{ "git", "show", "--histogram", "--diff-merges=1", "-p", sha.text().slice() },
        io,
    );
}

pub fn formatPatch(agent: Agent, sha: Sha, io: Io) ![]u8 {
    return try agent.exec(
        &.{ "git", "format-patch", "--histogram", "--stdout", sha.text().slice() },
        io,
    );
}

pub fn formatPatchRange(agent: Agent, range: []const u8, io: Io) ![]u8 {
    return try agent.exec(&.{ "git", "format-patch", "--histogram", "--stdout", range }, io);
}

pub fn checkPatch(agent: Agent, patch: []const u8, io: Io) !?[]u8 {
    const res = try agent.execCustomStdin(&.{
        "git",
        "apply",
        "--check",
        "--verbose",
        "--",
    }, patch, io);

    if (res.term.exited == 0) return null;
    std.debug.print("git apply error {}\n", .{res.term.exited});
    std.debug.print("stderr {s}", .{res.stderr});
    std.debug.print("stdout {s}", .{res.stdout});
    return error.DoesNotApply;
}

pub fn blame(agent: Agent, name: []const u8, ref: ?Ref, io: Io) ![]u8 {
    std.debug.print("Git blame on file {s}\n", .{name});

    const argv: []const []const u8 = if (ref) |r| switch (r) {
        .sha => |s| &.{ "git", "blame", "--porcelain", s.text().slice(), "--", name },
        inline else => |_, t| {
            std.debug.print("Git blame not implemented for {}\n", .{t});
            return error.NotImplemented;
        },
    } else &.{ "git", "blame", "--porcelain", "--", name };
    if (agent.execCustom(argv, io)) |res| {
        if (res.term != .exited or res.term.exited != 0) {
            std.debug.print("git Agent error\nstderr: {s}\n", .{res.stderr});
            agent.alloc.free(res.stderr);
            return error.BlameFailed;
        }
        return res.stdout;
    } else |err| return err;
}

pub const ExecResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
};

fn execCustomStdin(agent: Agent, argv: []const []const u8, stdin: []const u8, io: Io) !ExecResult {
    std.debug.assert(std.mem.eql(u8, argv[0], "git"));
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = &.init(agent.alloc),
        .expand_arg0 = .no_expand,
        .cwd = if (agent.cwd != null and agent.cwd.?.handle != Io.Dir.cwd().handle) .{ .dir = agent.cwd.? } else .inherit,
        .stdin = if (stdin.len > 0) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var stdout: Writer.Allocating = try .initCapacity(agent.alloc, 2048);
    var stderr: Writer.Allocating = try .initCapacity(agent.alloc, 2048);
    errdefer {
        stdout.deinit();
        stderr.deinit();
    }

    if (child.stdin) |cstdin| {
        var writer = cstdin.writer(io, &.{});
        try writer.interface.writeAll(stdin);
        cstdin.close(io);
        child.stdin = null;
    }

    defer if (child.stdout) |out| out.close(io);
    defer if (child.stderr) |err| err.close(io);

    var outr = child.stdout.?.reader(io, &.{});
    while (outr.interface.stream(&stdout.writer, .limited(0x800000))) |_| {
        //
    } else |e| switch (e) {
        error.EndOfStream => {},
        error.WriteFailed, error.ReadFailed => return e,
    }

    var errr = child.stderr.?.reader(io, &.{});
    while (errr.interface.stream(&stderr.writer, .limited(0x800000))) |_| {
        //
    } else |e| switch (e) {
        error.EndOfStream => {},
        error.WriteFailed, error.ReadFailed => return e,
    }

    return .{
        .term = child.wait(io) catch |err| {
            const errstr =
                \\git agent error:
                \\error :: {}
                \\argv ::
            ;
            std.debug.print(errstr, .{err});
            for (argv) |arg| std.debug.print("{s} ", .{arg});
            std.debug.print("\n", .{});
            return err;
        },
        .stdout = try stdout.toOwnedSlice(),
        .stderr = try stderr.toOwnedSlice(),
    };
}

fn execCustom(agent: Agent, argv: []const []const u8, io: Io) !ExecResult {
    return try agent.execCustomStdin(argv, &.{}, io);
}

fn exec(agent: Agent, argv: []const []const u8, io: Io) ![]u8 {
    const child = try agent.execCustom(argv, io);
    if (child.stderr.len > 0) {
        std.debug.print("git Agent error\nstderr: {s}\n", .{child.stderr});
    }
    defer agent.alloc.free(child.stderr);

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
    , .{ argv[1], child.stdout, child.stderr, agent.cwd });
    return child.stdout;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const log = std.log.scoped(.git_agent);
const find = std.mem.find;

const Repo = @import("Repo.zig");
const Tree = @import("tree.zig");
const Ref = @import("../git.zig").Ref;
const Sha = @import("Sha.zig");
