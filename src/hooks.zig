pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    const arg0 = args.next() orelse @panic("impressive, how'd you reach this?");
    std.debug.print("arg0: {s}\n", .{arg0});
    while (args.next()) |arg| {
        std.debug.print("arg: {s}\n", .{arg});
    }

    var stdin_f: std.Io.File = .stdin();
    var sin_b: [4096]u8 = undefined;
    var in_reader = stdin_f.reader(init.io, &sin_b);
    const stdin = &in_reader.interface;

    const env: Env = try .init(&init.minimal.environ, init.arena.allocator());

    if (endsWith(u8, arg0, "pre-receive")) {
        // https://git-scm.com/docs/githooks#pre-receives
        preReceive(stdin, &env) catch return 1;
    } else if (endsWith(u8, arg0, "post-receive")) {
        // https://git-scm.com/docs/githooks#post-receive
        postReceive(stdin, &env) catch return 1;
    } else if (endsWith(u8, arg0, "update")) {
        // https://git-scm.com/docs/githooks#update
        update(
            args.next() orelse return 255,
            args.next() orelse return 255,
            args.next() orelse return 255,
            &env,
        ) catch return 1;
    } else if (endsWith(u8, arg0, "post-update")) {
        // https://git-scm.com/docs/githooks#post-update
        postUpdate(&env) catch return 1;
    } else if (endsWith(u8, arg0, "proc-receive")) {
        // https://git-scm.com/docs/githooks#proc-receive
        procReceive(&env) catch return 1;
    }

    return 0;
}

pub fn preReceive(stdin: *Reader, _: *const Env) !void {
    // This hook is invoked by git-receive-pack[1] when it reacts to git
    // push and updates reference(s) in its repository. Just before
    // starting to update refs on the remote repository, the pre-receive
    // hook is invoked. Its exit status determines the success or failure
    // of the update.

    // This hook executes once for the receive operation. It takes no
    // arguments, but for each ref to be updated it receives on standard
    // input a line of the format:

    // <old-oid> SP <new-oid> SP <ref-name> LF

    // where <old-oid> is the old object name stored in the ref, <ne
    // -oid> is the new object name to be stored in the ref and <re
    // -name> is the full name of the ref. When creating a new ref,
    // <old-oid> is the all-zeroes object name.

    // If the hook exits with non-zero status, none of the refs will
    // be updated. If the hook exits with zero, updating of individual
    // refs can still be prevented by the update hook.
    while (stdin.takeSentinel('\n')) |line| {
        var itr = splitScalar(u8, line, ' ');

        const old = itr.next() orelse return error.InvalidReceiveLine;
        const new = itr.next() orelse return error.InvalidReceiveLine;
        const ref = itr.rest();
        std.debug.print("line: {s} {s} {s}\n", .{ old, new, ref });
    } else |_| return;
}

pub fn postReceive(stdin: *Reader, _: *const Env) !void {
    // The hook takes no arguments. It receives one line on standard
    // input for each ref that is successfully updated following the
    // same format as the pre-receive hook.
    while (stdin.takeSentinel('\n')) |line| {
        if (false) std.debug.print("line: {s}\n", .{line});
    } else |_| return;
}

pub fn update(ref: []const u8, old_oid: []const u8, target_oid: []const u8, env: *const Env) !void {
    // This hook is invoked by git-receive-pack[1] when it reacts to git
    // push and updates reference(s) in its repository. Just before
    // updating the ref on the remote repository, the update hook is
    // invoked. Its exit status determines the success or failure of the
    // ref update.
    //
    // The hook executes once for each ref to be updated, and takes three
    // parameters:
    //     the name of the ref being updated,
    //     the old object name stored in the ref,
    //     and the new object name to be stored in the ref.
    //
    // A zero exit from the update hook allows the ref to be updated.
    // Exiting with a non-zero status prevents git receive-pack from
    // updating that ref.
    //
    // This hook can be used to prevent forced update on certain refs
    // by making sure that the object name is a commit object that is
    // a descendant of the commit object named by the old object name.
    // That is, to enforce a "fast-forward only" policy.
    //
    // It could also be used to log the old..new status. However, it
    // does not know the entire set of branches, so it would end up
    // firing one e-mail per ref when used naively, though. The
    // post-receive hook is more suited to that.
    //
    // In an environment that restricts the users' access only to
    // git commands over the wire, this hook can be used to implement
    // access control without relying on filesystem ownership and
    // group membership. See git-shell[1] for how you might use the
    // login shell to restrict the user’s access to only git commands.
    if (false) std.debug.print("{s} {s} {s}\n", .{ ref, old_oid, target_oid });
    switch (env.method) {
        .unknown => return error.UnsupportedEnv,
        .http => return error.HttpPushDisabled,
        .git => return error.NotImplemented,
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

pub fn procReceive(_: *const Env) !void {
    // This hook is invoked by git-receive-pack[1]. If the server has set
    // the multi-valued config variable receive.procReceiveRefs, and the
    // commands sent to receive-pack have matching reference names, these
    // commands will be executed by this hook, instead of by the internal
    // execute_commands() function. This hook is responsible for updating
    // the relevant references and reporting the results back to
    // receive-pack.

    // This hook executes once for the receive operation. It takes no
    // arguments, but uses a pkt-line format protocol to communicate with
    // receive-pack to read commands, push-options and send results. In
    // the following example for the protocol, the letter S stands for
    // receive-pack and the letter H stands for this hook.
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
    method: PushMethod,
    push_options: ArrayList([]const u8),

    pub fn init(env: *const std.process.Environ, a: Allocator) !Env {
        var map = try env.createMap(a);
        var method: PushMethod = .unknown;
        if (map.contains("SRCTREE_HTTP")) {
            method = .http;
        }
        var list: ArrayList([]const u8) = .empty;
        if (map.contains("GIT_PUSH_OPTION_COUNT")) {
            const count = std.fmt.parseInt(usize, map.get("GIT_PUSH_OPTION_COUNT").?, 0) catch return error.BadEnvCount;
            if (count > 0) {
                var b: [64]u8 = undefined;
                for (0..count) |i| {
                    const opt_str = try std.fmt.bufPrint(&b, "GIT_PUSH_OPTION_{}", .{i});
                    const opt = map.get(opt_str) orelse return error.ExpectedEnvMissing;
                    try list.append(a, opt);
                }
            } else {
                if (method == .http) return error.HttpMissingOption;
            }
        }

        return .{
            .map = map,
            .method = method,
            .push_options = list,
        };
    }

    pub fn raze(env: Env, a: Allocator) void {
        env.map.deinit(a);
        env.push_options.deinit(a);
    }
};

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const endsWith = std.mem.endsWith;
const splitScalar = std.mem.splitScalar;
