pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    var args = init.minimal.args.iterate();
    const arg0 = args.next() orelse @panic("impressive, how'd you reach this?");

    var stdin_f: std.Io.File = .stdin();
    var sin_b: [4096]u8 = undefined;
    var in_reader = stdin_f.reader(init.io, &sin_b);
    const stdin = &in_reader.interface;

    var stdout_f: std.Io.File = .stdout();
    var sout_b: [512]u8 = undefined;
    var out_reader = stdout_f.writer(init.io, &sout_b);
    const stdout = &out_reader.interface;
    defer stdout.flush() catch {};

    const env = Env.init(&init.minimal.environ, a) catch |err| {
        std.debug.print("unable to set up hook env for '{s}' ({})\n", .{ arg0, err });
        return 4;
    };
    const cwd = std.Io.Dir.cwd();

    if (env.datadir) |datadir| {
        const dir = cwd.createDirPathOpen(io, datadir, .{ .open_options = .{ .iterate = true } }) catch {
            std.debug.print("unable to set up hook env\n", .{});
            return 4;
        };

        types.init(dir, io) catch {
            std.debug.print("unable to set up hook types\n", .{});
            return 4;
        };
    } else {
        //std.debug.print("DataDir unavailable\n", .{});
        //return 0;
    }

    if (endsWith(u8, arg0, "pre-receive")) {
        // https://git-scm.com/docs/githooks#pre-receives
        preReceive(stdin, &env) catch return 1;
        return 0;
    } else if (endsWith(u8, arg0, "post-receive")) {
        // https://git-scm.com/docs/githooks#post-receive
        postReceive(stdin, &env) catch return 1;
        return 0;
    } else if (endsWith(u8, arg0, "update")) {
        if (endsWith(u8, arg0, "post-update")) {
            // https://git-scm.com/docs/githooks#post-update
            postUpdate(&env) catch return 1;
        } else {
            // https://git-scm.com/docs/githooks#update
            const ref = args.next() orelse return 255;
            const old = args.next() orelse return 255;
            const new = args.next() orelse return 255;
            update(ref, old, new, &env, a, io) catch |err| {
                switch (err) {
                    error.UnsupportedEnv => {
                        std.debug.print("error: Server environ not set up correctly\n", .{});
                        return 1;
                    },
                    error.NoSpaceLeft => unreachable,
                    error.NotImplemented => unreachable,
                    //error.TargetExists => {
                    //    std.debug.print("error: Target ref already exists.\n", .{});
                    //    return 1;
                    //},
                    error.MalformedTarget => {
                        std.debug.print("error: You are unable to push to this ref\n", .{});
                        return 1;
                    },
                    error.FSFault => unreachable,
                    error.DeltaDoesNotExist => {
                        std.debug.print("error: Destination diff doesn't exist, or push isn't enabled for this repo/branch\n", .{});
                        return 1;
                    },
                }
            };
        }
        return 0;
    } else if (endsWith(u8, arg0, "proc-receive")) {
        // https://git-scm.com/docs/githooks#proc-receive
        procReceive(stdin, stdout, &env, a, io) catch return 1;
        return 0;
    } else {
        std.debug.print("Unable to route hook '{s}'\n", .{arg0});
        std.debug.print("Unable to route hook '{any}'\n", .{arg0});
        return 1;
    }
}

pub fn preReceive(stdin: *Reader, _: *const Env) !void {
    // This hook executes once for the receive operation. It takes no arguments,
    // but for each ref to be updated it receives on standard input a line of
    // the format: <old-oid> SP <new-oid> SP <ref-name> LF

    // If the hook exits with non-zero status, none of the refs will
    // be updated. If the hook exits with zero, updating of individual
    // refs can still be prevented by the update hook.
    while (stdin.takeSentinel('\n')) |line| {
        var itr = splitScalar(u8, line, ' ');

        const old = itr.next() orelse return error.InvalidReceiveLine;
        const new = itr.next() orelse return error.InvalidReceiveLine;
        const ref = itr.rest();
        if (false) std.debug.print("line: {s} {s} {s}\n", .{ old, new, ref });
    } else |_| return;
}

pub fn postReceive(stdin: *Reader, _: *const Env) !void {
    //std.debug.print("post receive\n", .{});
    while (stdin.takeSentinel('\n')) |line| {
        if (false) std.debug.print("line: {s}\n", .{line});
    } else |_| return;
}

/// NOTE: update may not get `refname` changes from procReceieve
pub fn update(
    ref: []const u8,
    old_oid: []const u8,
    target_oid: []const u8,
    env: *const Env,
    a: Allocator,
    io: std.Io,
) !void {
    if (false) std.debug.print("update {s} {s} {s}\n", .{ ref, old_oid, target_oid });
    switch (env.method) {
        .unknown => return error.UnsupportedEnv,
        .git => return error.NotImplemented,
        .http => {
            if (env.datadir == null) return error.UnsupportedEnv;
            if (!eql(u8, old_oid, &@as([32]u8, @splat(0)))) {
                if (false and true) return error.TargetExists;
            }
            if (cutPrefix(u8, ref, "refs/heads/diffs/")) |dif_num| {
                const idx = parseInt(usize, dif_num, 0) catch return error.MalformedTarget;
                var delta = Delta.open(env.repo.?, idx, a, io) catch |err| {
                    return err;
                };
                _ = &delta;
            }
        },
        .ssh => {},
        .file => {},
    }
}

pub fn postUpdate(_: *const Env) !void {
    // This hook is invoked by git-receive-pack[1] when it reacts to git
    // push and updates reference(s) in its repository. It executes on
    // the remote repository once after all the refs have been updated.
    //
    // It takes a variable number of parameters, each of which is the
    // name of ref that was actually updated.
    //
    // This hook is meant primarily for notification, and cannot affect
    // the outcome of git receive-pack.
    //
    // The post-update hook can tell what are the heads that were pushed,
    // but it does not know what their original and updated values are,
    // so it is a poor place to do log old..new. The post-receive hook
    // does get both original and updated values of the refs. You might
    // consider it instead if you need them.
    //
    // When enabled, the default post-update hook runs git
    // update-server-info to keep the information used by dumb
    // transports (e.g., HTTP) up to date. If you are publishing a Git
    // repository that is accessible via HTTP, you should probably enable
    // this hook.
}

pub const diffs = struct {
    pub fn new(
        env: *const Env,
        pr: ProcRecv,
        repo: *const git.Repo,
        dir: Io.Dir,
        w: *Writer,
        a: Allocator,
        io: Io,
    ) !void {
        const cmt = try repo.commit(pr.new, a, io);
        const user = cmt.committer.name;
        var delta = try Delta.new(env.repo.?, std.mem.trim(u8, cmt.title, "\n "), cmt.body, user, io);

        var b: [512]u8 = undefined;
        const ref_head = print(&b, "refs/diffs/{}/head", .{delta.index}) catch unreachable;
        const ref_dir = ref_head[0 .. ref_head.len - 5];
        if (try dir.createDirPathStatus(io, ref_dir, .default_dir) == .created) {
            var diff: Diff = try .new(&delta, user, "", a, io);
            try diff.commit(io);
            try delta.commit(io);
        } else {
            return diffs.update(pr, &delta, dir, w, a, io);
        }
        var hash_buf: [512]u8 = undefined;
        const target = try print(&hash_buf, "{f}\n", .{pr.new.text()});
        try dir.writeFile(io, .{ .sub_path = ref_head, .data = target });
        try pr.writeOptions(w, .refname(ref_head));
    }

    pub fn update(
        pr: ProcRecv,
        delta: *const Delta,
        dir: Io.Dir,
        w: *Writer,
        a: Allocator,
        io: Io,
    ) !void {
        switch (delta.attach) {
            .nos, .diff => {},
            else => @panic("not implemented"),
        }
        var diff: Diff = try Diff.open(delta.attach_target, a, io) orelse return error.DiffMissing;
        diff.revision +%= 1;
        diff.commit(io) catch {};

        var hash_buf: [512]u8 = undefined;
        const target = try print(&hash_buf, "{f}\n", .{pr.new.text()});
        var b: [512]u8 = undefined;
        const ref_head = print(&b, "refs/diffs/{d}/head", .{delta.index}) catch return error.FileSystemFailed;
        try dir.writeFile(io, .{ .sub_path = ref_head, .data = target });
        const revision = print(&b, "refs/diffs/{d}/rev-{d}", .{ delta.index, diff.revision }) catch return error.FileSystemFailed;
        try dir.writeFile(io, .{ .sub_path = revision, .data = target });

        try pr.writeOptions(w, .refname(ref_head));
    }

    pub fn updateHead(pr: ProcRecv, repo_name: []const u8, ref_str: []const u8, dir: Io.Dir, w: *Writer, a: Allocator, io: Io) !void {
        if (cutPrefix(u8, ref_str, "refs/diffs/")) |num_head| {
            if (cutSuffix(u8, num_head, "/head")) |num| {
                const delta_id = parseInt(usize, num, 0) catch return error.InvalidDeltaId;
                const delta: Delta = try .open(repo_name, delta_id, a, io);
                return diffs.update(pr, &delta, dir, w, a, io);
            }
        }
    }
};

pub fn procReceive(in: *Reader, out: *Writer, env: *const Env, a: Allocator, io: Io) !void {
    const dir = try std.Io.Dir.cwd().openDir(io, ".", .{});
    var repo: git.Repo = try .init(dir, io);
    try repo.loadData(a, io);
    defer repo.raze(a, io);

    _ = try PktLine.read(in); // header
    _ = try PktLine.read(in); // flush
    try PktLine.write(out, "version=1\x00push-options agent=srctree/0.0.0\n");
    try PktLine.writeFlush(out);

    defer PktLine.writeFlush(out) catch {};

    while (PktLine.read(in)) |line| switch (line) {
        .flush => break,
        .bytes => |bytes| {
            const pr: ProcRecv = try .init(std.mem.trim(u8, bytes, "\n "));
            if (cutPrefix(u8, pr.ref, "refs/")) |refroot| {
                const ref = cutPrefix(u8, refroot, "heads/") orelse refroot;
                if (cutPrefix(u8, ref, "diffs/")) |base| {
                    if (eql(u8, base, "new")) {
                        if (!env.authenticated) {
                            const cmt = try repo.commit(pr.new, a, io);
                            const head = try repo.HEAD(a, io);
                            if (!head.sha.eql(cmt.parent[0].?)) {
                                try pr.nak("unauthenticated (commit history too long)", out);
                                continue;
                            }
                        }
                        try diffs.new(env, pr, &repo, dir, out, a, io);
                        continue;
                    } else if (endsWith(u8, base, "/head")) {
                        try diffs.updateHead(pr, env.repo.?, base, dir, out, a, io);
                        continue;
                    }
                } else if (!env.authenticated) {
                    try pr.nak("unauthenticated (invalid target)", out);
                    return error.PushDenied;
                } else {
                    try pr.fallThrough(out);
                }
            } else {
                try pr.nak(if (!env.authenticated)
                    "unauthenticated (invalid target)"
                else
                    "invalid ref", out);
                return error.PushDenied;
            }
        },
        else => return {},
    } else |e| switch (e) {
        error.EndOfStream => {},
        else => return e,
    }
}

const PushMethod = enum {
    unknown,
    http,
    git,
    ssh,
    file,
};

const Env = struct {
    map: std.process.Environ.Map,
    push_options: StringArrayHashMap(void),
    method: PushMethod,
    host: ?[]const u8,
    repo: ?[]const u8,
    datadir: ?[]const u8,

    user: ?[]const u8 = null,
    authenticated: bool = false,

    pub fn init(env: *const std.process.Environ, a: Allocator) !Env {
        var map = try env.createMap(a);
        var method: PushMethod = .unknown;
        const host: ?[]const u8 = map.get("SRCTREE_HOST");
        const repo: ?[]const u8 = map.get("SRCTREE_REPO");
        const user: ?[]const u8 = map.get("SRCTREE_USER");
        var datadir: ?[]const u8 = map.get("SRCTREE_DIRECT_DATADIR");

        if (map.contains("SRCTREE_HTTP")) {
            method = .http;
        } else if (map.contains("SSH_CLIENT")) {
            method = .ssh;
        }

        if (map.contains("SRCTREE_DIRECT_ENABLED")) {
            if (!eql(u8, map.get("SRCTREE_DIRECT_ENABLED").?, "true"))
                datadir = null;
        } else {
            datadir = null;
        }

        var list: StringArrayHashMap(void) = .empty;
        if (map.contains("GIT_PUSH_OPTION_COUNT")) {
            const count = parseInt(usize, map.get("GIT_PUSH_OPTION_COUNT").?, 0) catch return error.BadEnvCount;
            if (count > 0) {
                var b: [64]u8 = undefined;
                for (0..count) |i| {
                    const opt_str = try print(&b, "GIT_PUSH_OPTION_{}", .{i});
                    const opt = map.get(opt_str) orelse return error.ExpectedEnvMissing;
                    try list.put(a, opt, {});
                }
            }
        }

        return .{
            .map = map,
            .push_options = list,
            .method = method,
            .repo = repo,
            .host = host,
            .datadir = datadir,
            .user = user,
            // TODO better authentication
            .authenticated = method == .ssh or user != null and !startsWith(u8, user.?, "anon"),
        };
    }

    pub fn raze(env: Env, a: Allocator) void {
        env.map.deinit(a);
        env.push_options.deinit(a);
    }

    pub fn format(env: Env, w: *std.Io.Writer) !void {
        try w.print("Env:\n", .{});
        try w.print("Host: '{s}' Repo: '{s}' User: '{s}'\n", .{
            env.host orelse "null",
            env.repo orelse "null",
            env.user orelse "null",
        });
        for (env.push_options.keys()) |e| {
            try w.print("    push-option: '{s}'\n", .{e});
        }
        for (env.map.keys(), env.map.values()) |k, v| {
            try w.print("    map: k:'{s}' v:'{s}'\n", .{ k, v });
        }
    }
};

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const eql = std.mem.eql;
const endsWith = std.mem.endsWith;
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;
const cutPrefix = std.mem.cutPrefix;
const cutSuffix = std.mem.cutSuffix;
const parseInt = std.fmt.parseInt;
const types = @import("types.zig");
const Delta = types.Delta;
const Diff = types.Diff;
const StringArrayHashMap = std.StringArrayHashMapUnmanaged;
const git = @import("git.zig");
const PktLine = git.protocol.PktLine;
const ProcRecv = git.protocol.ProcRecv;
const print = std.fmt.bufPrint;
