/// Aligned to Git.Repo for @fieldParentPtr
enabled: bool align(8) = false,
srctree: RepoCiConf = .empty,
conf_bytes: [:0]const u8 = &.{},
working_dir: ?Io.Dir = null,
artifacts: Artifacts = .{},
cache: Cache = .{},
source: Source = undefined,

const Ci = @This();

pub const RepoCiConf = struct {
    ci: ?[]const u8,
    docs: ?[]const u8,

    pub const empty: RepoCiConf = .{
        .ci = null,
        .docs = null,
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
                    ci.srctree = std.zon.parse.fromSliceAlloc(RepoCiConf, a, ci.conf_bytes, null, .{
                        .ignore_unknown_fields = true,
                    }) catch return false;

                    ci.enabled = true;
                    return ci.enabled;
                },
                else => {},
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

    try ci.source.init(repo.name.?, commit, a, io);
    defer ci.source.raze(a, io);
    try ci.source.checkout(a, io);

    try ci.cache.inject(a, io);
    defer ci.cache.backup(a, io) catch unreachable;

    try ci.artifacts.init(a, io);
    defer ci.artifacts.save(a, io) catch unreachable;

    try ci.source.stepSetup(a, io);
    try ci.source.stepBuild(a, io);
    try ci.source.stepTests(a, io);

    // save build output
}

pub fn raze(ci: *Ci, a: Allocator, io: Io) void {
    if (ci.working_dir) |*wd| wd.close(io);
    a.free(ci.conf_bytes);
}

pub fn validate(ci: *Ci, a: Allocator, io: Io) !void {
    _ = ci;
    _ = a;
    _ = io;
}

pub const Artifacts = struct {
    pub fn init(art: *Artifacts, a: Allocator, io: Io) !void {
        _ = art;
        _ = a;
        _ = io;
    }

    pub fn save(art: *Artifacts, a: Allocator, io: Io) !void {
        _ = art;
        _ = a;
        _ = io;
    }
};

pub const Source = struct {
    working_dir: Io.Dir,
    tree: git.Tree,

    pub fn init(src: *Source, name: []const u8, commit: *const git.Commit, a: Allocator, io: Io) !void {
        const ci: *Ci = @fieldParentPtr("source", src);
        const repo: *Repo = @fieldParentPtr("ci", ci);
        if (ci.working_dir) |wdir| {
            src.working_dir = try wdir.createDirPathOpen(io, name, .{
                .open_options = .{ .iterate = true },
            });
        }
        src.tree = try commit.loadTree(&repo.git, a, io);
    }

    pub fn checkout(src: *Source, a: Allocator, io: Io) !void {
        const ci: *Ci = @fieldParentPtr("source", src);
        const r: *Repo = @fieldParentPtr("ci", ci);
        try src.tree.checkout(src.working_dir, &r.git, a, io);
    }

    pub fn stepSetup(src: *Source, a: Allocator, io: Io) !void {
        _ = src;
        _ = a;
        _ = io;
    }

    pub fn stepBuild(src: *Source, a: Allocator, io: Io) !void {
        var stdout: Io.Writer.Allocating = .init(a);
        var stderr: Io.Writer.Allocating = .init(a);
        defer stdout.deinit();
        defer stderr.deinit();
        try src.exec(&.{ "zig", "build" }, &stdout.writer, &stderr.writer, null, io);
    }

    pub fn stepTests(src: *Source, a: Allocator, io: Io) !void {
        _ = src;
        _ = a;
        _ = io;
    }

    pub fn raze(src: *Source, a: Allocator, io: Io) void {
        src.working_dir.close(io);
        src.tree.raze(a);
    }

    fn exec(
        src: *Source,
        argv: []const []const u8,
        stdout: *Io.Writer,
        stderr: *Io.Writer,
        stdin: ?[]const u8,
        io: Io,
    ) !void {
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .expand_arg0 = .no_expand,
            .cwd = .{ .dir = src.working_dir },
            .stdin = if (stdin != null) .pipe else .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
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
    pub fn inject(c: *Cache, _: Allocator, _: Io) !void {
        if (Cache.enabled()) return;
        const ci: *Ci = @alignCast(@fieldParentPtr("cache", c));
        _ = ci;
    }

    pub fn backup(c: *Cache, _: Allocator, _: Io) !void {
        if (Cache.enabled()) return;
        const ci: *Ci = @alignCast(@fieldParentPtr("cache", c));
        _ = ci;
    }

    fn enabled() bool {
        if (global_config.ci) |ci| {
            if (ci.cache_enabled) |en| {
                return en;
            } else return false;
        } else return false;
    }
};

test {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tdir = std.testing.tmpDir(.{ .iterate = true });
    defer tdir.cleanup();

    global_config.ci = .default;

    const cwd = try Io.Dir.cwd().openDir(io, ".", .{});
    var repo = try Repo.init("srctree", cwd, io);
    defer repo.raze(a, io);
    try repo.git.loadData(a, io);
    var commit = try repo.git.HEAD(a, io);
    defer commit.raze(a);

    repo.ci.enabled = true;
    try repo.ci.prepare(io);

    repo.ci.working_dir = tdir.dir;

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
