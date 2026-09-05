/// Aligned to Git.Repo for @fieldParentPtr
enabled: bool align(8) = false,
conf_zon: ?CiZon = null,
conf_bytes: [:0]const u8 = &.{},
working_dir: ?Io.Dir = null,
source: Source = .{},
cache: Cache = .{},
artifacts: Artifacts = .{},

const Ci = @This();

pub const Result = enum(u8) {
    unknown,
    pending,
    waiting,
    started,
    running,
    stalled,
    passed,
    failed,
    err,
};

pub const CiZon = struct {
    srctree: ?SrctreeZon,

    pub const SrctreeZon = struct {
        ci: ?[]const u8,
        docs: ?[]const u8,

        pub const empty: SrctreeZon = .{
            .ci = null,
            .docs = null,
        };
    };

    pub const empty: CiZon = .{
        .srctree = .empty,
    };
};

pub fn status(ci: *Ci, a: Allocator, io: Io) !bool {
    const repo: *Repo = @fieldParentPtr("ci", ci);
    ci.enabled = false;
    const commit = repo.git.HEAD(a, io) catch return false; // empty or broken repo
    defer commit.raze(a);
    const tree = try commit.loadTree(&repo.git, a, io);
    defer tree.raze(a);
    var itr = tree.iterate();
    while (itr.next()) |next| {
        if (eql(u8, next.name, "build.zig.zon")) {
            const blob = try repo.git.objects.load(next.sha, a, io);
            switch (blob) {
                .blob => if (find(u8, blob.blob.data.blob, ".srctree =")) |_| {
                    defer blob.blob.raze(a);
                    ci.conf_bytes = try a.dupeSentinel(u8, blob.blob.data.blob, 0);
                    ci.conf_zon = std.zon.parse.fromSliceAlloc(CiZon, a, ci.conf_bytes, null, .{
                        .ignore_unknown_fields = true,
                    }) catch |err| {
                        log.err("unable to parse zon {}", .{err});
                        return false;
                    };

                    ci.enabled = true;
                    return ci.enabled;
                } else return false,
                else => unreachable,
            }
        }
    }
    return ci.enabled;
}

pub fn prepare(ci: *Ci, io: Io) !void {
    if (global_config.ci) |c| {
        if (c.working_path) |path| {
            ci.working_dir = try std.Io.Dir.cwd().createDirPathOpen(
                io,
                path,
                .{ .open_options = .{ .iterate = true } },
            );
            return;
        } else return error.ConfigMissingCi;
    } else return error.ConfigMissing;
}

pub fn run(ci: *Ci, commit: *const git.Commit, a: Allocator, io: Io) !void {
    const repo: *Repo = @fieldParentPtr("ci", ci);
    if (!ci.enabled) return error.Disabled;
    // load instructions
    try ci.validate(a, io);

    var ci_res = try types.CI.new(repo, "[undefined]", .pending, types.shaToHash(commit.sha), io);
    _ = &ci_res;

    try ci.source.init(repo.name.?, commit, a, io);
    defer ci.source.raze(a, io);
    try ci.source.checkout(a, io);

    try ci.cache.init(io);
    defer ci.cache.raze(a, io);

    try ci.cache.inject(ci.source.dir, a, io);
    defer ci.cache.backup(ci.source.dir, a, io);

    try ci.artifacts.init(ci.source.dir, commit.sha, a, io);
    defer ci.artifacts.save(a, io);

    try ci.source.setup(a, io);
    try ci.source.buildMain(a, io);
    try ci.source.buildTests(a, io);
    try ci.source.buildDocs(a, io);

    // save build output
}

pub fn raze(ci: *Ci, a: Allocator, io: Io) void {
    if (ci.working_dir) |*wd| wd.close(io);
    if (ci.conf_bytes.len > 0) a.free(ci.conf_bytes);
    if (ci.conf_zon) |zon| std.zon.parse.free(a, zon);
}

pub fn validate(ci: *Ci, a: Allocator, io: Io) !void {
    _ = ci;
    _ = a;
    _ = io;
}

pub const Artifacts = struct {
    src: Io.Dir = undefined,
    sha: git.Sha = undefined,

    pub fn init(art: *Artifacts, src_dir: Io.Dir, sha: git.Sha, _: Allocator, _: Io) !void {
        art.* = .{
            .src = src_dir,
            .sha = sha,
        };
    }

    pub fn save(art: *Artifacts, a: Allocator, io: Io) void {
        const ci: *Ci = @alignCast(@fieldParentPtr("artifacts", art));
        //const repo: *Repo = @fieldParentPtr("ci", ci);
        if (ci.conf_zon.?.srctree) |zon| {
            if (zon.docs) |_| art.saveDocs(a, io);
        }
    }

    fn saveDocs(art: *Artifacts, _: Allocator, io: Io) void {
        const ci: *Ci = @alignCast(@fieldParentPtr("artifacts", art));
        const repo: *Repo = @fieldParentPtr("ci", ci);
        const zig_out = art.src.openDir(io, "zig-out", .{}) catch |err| {
            if (err != error.NotDir)
                log.err("unable to open `zig-out' {}", .{err});
            return;
        };
        _ = zig_out.statFile(io, "docs", .{}) catch |err| {
            log.err("Unable to stat docs {}", .{err});
            return;
        };
        const dest = types.iterableDir(.artifiact, io) catch unreachable;
        const repo_dir = dest.createDirPathOpen(io, repo.name.?, .{}) catch unreachable;
        zig_out.renamePreserve("docs", repo_dir, "docs", io) catch |err| {
            if (err == error.NotDir) return; // expected
            log.err("unable to inject cache {}", .{err});
        };
    }
};

pub const Source = struct {
    dir: Io.Dir = undefined,
    commit: *const git.Commit = undefined,
    tree: git.Tree = undefined,

    pub fn init(src: *Source, name: []const u8, commit: *const git.Commit, a: Allocator, io: Io) !void {
        const ci: *Ci = @fieldParentPtr("source", src);
        const repo: *Repo = @fieldParentPtr("ci", ci);
        if (ci.working_dir) |wdir| {
            const dir = try wdir.createDirPathOpen(io, name, .{
                .open_options = .{ .iterate = true },
            });

            const tree = try commit.loadTree(&repo.git, a, io);
            src.* = .{
                .dir = dir,
                .tree = tree,
                .commit = commit,
            };
            return;
        }
        return error.Unreachable;
    }

    pub fn checkout(src: *Source, a: Allocator, io: Io) !void {
        const ci: *Ci = @fieldParentPtr("source", src);
        const r: *Repo = @fieldParentPtr("ci", ci);
        try src.tree.checkout(src.dir, &r.git, a, io);
    }

    pub fn setup(src: *Source, a: Allocator, io: Io) !void {
        _ = src;
        _ = a;
        _ = io;
    }

    pub fn buildMain(src: *Source, a: Allocator, io: Io) !void {
        var stdout: Io.Writer.Allocating = .init(a);
        var stderr: Io.Writer.Allocating = .init(a);
        defer stdout.deinit();
        defer stderr.deinit();
        try src.exec(&.{ "zig", "build", "--summary", "all" }, &stdout.writer, &stderr.writer, null, a, io);
        std.debug.print("stdout: '{s}'\n", .{stdout.written()});
        std.debug.print("stderr: '{s}'\n", .{stderr.written()});
    }

    pub fn buildTests(src: *Source, a: Allocator, io: Io) !void {
        var stdout: Io.Writer.Allocating = .init(a);
        var stderr: Io.Writer.Allocating = .init(a);
        defer stdout.deinit();
        defer stderr.deinit();
        try src.exec(&.{ "zig", "build", "--summary", "all", "test" }, &stdout.writer, &stderr.writer, null, a, io);
        std.debug.print("stdout: '{s}'\n", .{stdout.written()});
        std.debug.print("stderr: '{s}'\n", .{stderr.written()});
    }

    pub fn buildDocs(src: *Source, a: Allocator, io: Io) !void {
        var stdout: Io.Writer.Allocating = .init(a);
        var stderr: Io.Writer.Allocating = .init(a);
        defer stdout.deinit();
        defer stderr.deinit();
        try src.exec(&.{ "zig", "build", "--summary", "all", "docs" }, &stdout.writer, &stderr.writer, null, a, io);
        std.debug.print("stdout: '{s}'\n", .{stdout.written()});
        std.debug.print("stderr: '{s}'\n", .{stderr.written()});
    }

    pub fn raze(src: *Source, a: Allocator, io: Io) void {
        src.dir.close(io);
        src.tree.raze(a);
    }

    fn exec(
        src: *Source,
        argv: []const []const u8,
        stdout: *Io.Writer,
        stderr: *Io.Writer,
        stdin: ?[]const u8,
        a: Allocator,
        io: Io,
    ) !void {
        const map: std.process.Environ.Map = .{
            .array_hash_map = try .init(
                a,
                &.{"ZIG_GLOBAL_CACHE_DIR"},
                &.{"working/"},
            ),
            .allocator = undefined,
        };

        var child = try std.process.spawn(io, .{
            .argv = argv,
            .expand_arg0 = .no_expand,
            .cwd = .{ .dir = src.dir },
            .stdin = if (stdin != null) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            .environ_map = &map,
        });

        if (child.stdin) |cstdin| {
            var writer = cstdin.writer(io, &.{});
            try writer.interface.writeAll(stdin.?);
            cstdin.close(io);
            child.stdin = null;
        }
        defer if (child.stdout) |out| out.close(io);
        defer if (child.stderr) |err| err.close(io);

        var outr = child.stdout.?.reader(io, &.{});
        _ = try outr.interface.streamRemaining(stdout);

        var errr = child.stderr.?.reader(io, &.{});
        _ = try errr.interface.streamRemaining(stderr);

        _ = child.wait(io) catch |err| {
            log.warn("{any}: {}", .{ argv, err });
            return err;
        };
    }
};

pub const Cache = struct {
    dir: Io.Dir = undefined,

    pub fn init(c: *Cache, io: Io) !void {
        if (!Cache.enabled()) return;
        const ci: *Ci = @alignCast(@fieldParentPtr("cache", c));
        const r: *Repo = @fieldParentPtr("ci", ci);
        if (ci.working_dir) |wdir| {
            if (cfgPath()) |path| {
                const path_dir = try wdir.createDirPathOpen(io, path, .{});
                defer path_dir.close(io);
                c.dir = try path_dir.createDirPathOpen(io, r.name.?, .{
                    .open_options = .{ .iterate = true },
                });
            } else return error.BadConfig;
        } else unreachable;
    }

    pub fn raze(c: *Cache, _: Allocator, io: Io) void {
        if (!Cache.enabled()) return;
        c.dir.close(io);
    }

    pub fn inject(c: *Cache, dest_dir: Io.Dir, _: Allocator, io: Io) !void {
        if (!Cache.enabled()) return;
        c.dir.renamePreserve("zig-cache", dest_dir, ".zig-cache", io) catch |err| {
            if (err == error.NotDir) return; // expected
            log.err("unable to inject cache {}", .{err});
        };
    }

    pub fn backup(c: *Cache, src_dir: Io.Dir, _: Allocator, io: Io) void {
        if (!Cache.enabled()) return;
        _ = src_dir.statFile(io, ".zig-cache", .{}) catch |err| {
            log.err("Unable to stat cache dir {}", .{err});
        };
        src_dir.renamePreserve(".zig-cache", c.dir, "zig-cache", io) catch |err| {
            log.err("Unable to backup cache dir {}", .{err});
        };
    }

    fn cfgPath() ?[]const u8 {
        if (global_config.ci) |ci| {
            if (ci.cache_path) |path| {
                return path;
            }
        }
        return null;
    }

    fn enabled() bool {
        if (global_config.ci) |ci| {
            if (ci.cache_enabled) |en| {
                if (!en) return false;
                return ci.cache_path != null;
            } else return false;
        } else return false;
    }
};

test {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tdir = std.testing.tmpDir(.{ .iterate = true });
    defer tdir.cleanup();

    if (!config.full_ci) return error.SkipZigTest;

    global_config.ci = .default;
    global_config.ci.?.cache_path = "local_cache";
    global_config.ci.?.cache_enabled = true;

    const cwd = try Io.Dir.cwd().openDir(io, ".", .{});
    var repo = try Repo.init("srctree", cwd, io);
    defer repo.raze(a, io);
    try repo.git.loadData(a, io);
    var commit = try repo.git.HEAD(a, io);
    defer commit.raze(a);

    const stats = try repo.ci.status(a, io);
    if (false) std.debug.print("repo.ci = {any} {any}\n", .{ repo.ci.conf_zon, stats });

    try std.testing.expectEqual(true, repo.ci.enabled);
    try repo.ci.prepare(io);

    const old_dir = repo.ci.working_dir;
    repo.ci.working_dir = tdir.dir;
    defer repo.ci.working_dir = old_dir;

    try repo.ci.run(&commit, a, io);

    var w = try tdir.dir.walk(a);
    defer w.deinit();
    var c: usize = 0;
    var b: [0x8000]u8 = undefined;
    while (try w.next(io)) |file| {
        c += 1;
        if (eql(u8, file.path, "srctree/build.zig.zon")) {
            const file_data = try tdir.dir.readFile(io, file.path, &b);

            if (find(u8, file_data, ".fingerprint = 0x4eee355ffa6e50b7,") == null) {
                return error.FingerprintMissing;
            }
        }
        log.debug("walk {s}", .{file.path});
    }
    try std.testing.expect(c > 20); // Assume we have at least 20 files in this repo
}

const Repo = @import("../Repo.zig");
const std = @import("std");
const log = std.log.scoped(.ci);
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const eql = std.mem.eql;
const find = std.mem.find;
const parseInt = std.fmt.parseInt;
const git = @import("../git.zig");
const global_config = &@import("../Config.zig").global;
const config = @import("config");
const types = @import("../types.zig");
