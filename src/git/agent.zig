alloc: Allocator,
repo: ?*const Repo = null,
cwd: ?Io.Dir = null,

const Agent = @This();

const DEBUG_GIT_ACTIONS = false;

pub fn pullUpstream(self: Agent, branch: []const u8, io: Io) !void {
    const fetch = try self.exec(&[_][]const u8{
        "git",
        "fetch",
        "upstream",
        "-q",
    }, io);
    if (fetch.len > 0) log.warn("fetch {s}", .{fetch});
    self.alloc.free(fetch);

    var buf: [512]u8 = undefined;
    const up_branch = try std.fmt.bufPrint(&buf, "upstream/{s}", .{branch});
    const pull = try self.execCustom(&[_][]const u8{
        "git",
        "merge-base",
        "--is-ancestor",
        "HEAD",
        up_branch,
    }, io);
    defer self.alloc.free(pull.stdout);
    defer self.alloc.free(pull.stderr);

    if (pull.term.exited == 0) {
        const move = try self.exec(&[_][]const u8{
            "git",
            "fetch",
            "upstream",
            "*:*",
            "-q",
        }, io);
        self.alloc.free(move);
        return;
    }

    log.warn("refusing to move head non-ancestor {s}", .{up_branch});
    return error.NonAncestor;
}

pub fn pushDownstream(self: Agent, io: Io) !bool {
    const push = try self.exec(&[_][]const u8{
        "git",
        "push",
        "downstream",
        "*:*",
        "--porcelain",
    }, io);
    std.debug.print("pushing downstream ->\n{s}\n", .{push});
    self.alloc.free(push);
    return true;
}

pub fn forkRemote(self: Agent, uri: []const u8, local_dir: []const u8, io: Io) ![]u8 {
    const child = try self.execCustom(&[_][]const u8{
        "git",
        "clone",
        "--bare",
        "--origin",
        "upstream",
        uri,
        local_dir,
    }, io);
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

pub fn initRepo(self: Agent, dir: []const u8, opt: struct { bare: bool = true }, io: Io) ![]u8 {
    return try self.exec(&[_][]const u8{ "git", "init", if (opt.bare) "--bare" else "", dir }, io);
}

pub fn show(self: Agent, sha: SHA, io: Io) ![]u8 {
    return try self.exec(&[_][]const u8{
        "git",
        "show",
        "--histogram",
        "--diff-merges=1",
        "-p",
        sha.hex()[0 .. sha.len * 2],
    }, io);
}

pub fn formatPatch(self: Agent, sha: SHA, io: Io) ![]u8 {
    return try self.exec(&[_][]const u8{
        "git",
        "format-patch",
        "--histogram",
        "--stdout",
        sha.hex()[0 .. sha.len * 2],
    }, io);
}

pub fn formatPatchRange(self: Agent, range: []const u8, io: Io) ![]u8 {
    return try self.exec(&[_][]const u8{
        "git",
        "format-patch",
        "--histogram",
        "--stdout",
        range,
    }, io);
}

pub fn checkPatch(self: Agent, patch: []const u8, io: Io) !?[]u8 {
    const res = try self.execCustomStdin(&.{
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

pub fn blame(self: Agent, name: []const u8, ref: ?Ref, io: Io) ![]u8 {
    std.debug.print("Git blame on file {s}\n", .{name});

    const argv: []const []const u8 = if (ref) |r| switch (r) {
        .sha => |s| &[_][]const u8{
            "git",
            "blame",
            "--porcelain",
            s.hex()[0..40],
            "--",
            name,
        },
        inline else => |_, t| {
            std.debug.print("Git blame not implemented for {}\n", .{t});
            return error.NotImplemented;
        },
    } else &[_][]const u8{
        "git",
        "blame",
        "--porcelain",
        "--",
        name,
    };
    if (self.execCustom(argv, io)) |res| {
        if (res.term != .exited or res.term.exited != 0) {
            std.debug.print("git Agent error\nstderr: {s}\n", .{res.stderr});
            self.alloc.free(res.stderr);
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

fn execCustomStdin(self: Agent, argv: []const []const u8, stdin: []const u8, io: Io) !ExecResult {
    std.debug.assert(std.mem.eql(u8, argv[0], "git"));
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .expand_arg0 = .expand,
        .cwd = if (self.cwd != null and self.cwd.?.handle != Io.Dir.cwd().handle) .{ .dir = self.cwd.? } else .inherit,
        .stdin = if (stdin.len > 0) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var stdout: Writer.Allocating = .init(self.alloc);
    var stderr: Writer.Allocating = .init(self.alloc);
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
    var errr = child.stderr.?.reader(io, &.{});
    _ = outr.interface.stream(&stdout.writer, .limited(0x800000)) catch |e| switch (e) {
        error.EndOfStream => {},
        else => return e,
    };
    _ = errr.interface.stream(&stderr.writer, .limited(0x800000)) catch |e| switch (e) {
        error.EndOfStream => {},
        else => return e,
    };

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

fn execCustom(self: Agent, argv: []const []const u8, io: Io) !ExecResult {
    std.debug.assert(std.mem.eql(u8, argv[0], "git"));
    return self.execCustomStdin(argv, &.{}, io);
}

fn exec(self: Agent, argv: []const []const u8, io: Io) ![]u8 {
    const child = try self.execCustom(argv, io);
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
const Io = std.Io;
const Writer = Io.Writer;
const log = std.log.scoped(.git_agent);

const Repo = @import("Repo.zig");
const Tree = @import("tree.zig");
const Ref = @import("ref.zig").Ref;
const SHA = @import("SHA.zig");
