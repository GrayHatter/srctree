bare: bool,
dir: Dir,
objects: Objects,
refs: []Ref,
current: ?[]u8 = null,
head: ?Ref = null,
// Leaks, badly
tags: ?[]Tag = null,
branches: ?[]Branch = null,
remotes: ?[]Remote = null,
config: ?Ini.Config(Config).Base = null,
config_ini: ?Ini.Config(Config) = null,
repo_name: ?[]const u8 = null,

const Repo = @This();

pub const default: Repo = .{
    .bare = false,
    .dir = undefined,
    .objects = undefined,
    .refs = &[0]Ref{},
};

pub const Error = error{
    ReadError,
    NotAGitRepo,
    RefMissing,
    CommitMissing,
    InvalidCommit,
    InvalidTree,
    ObjectMissing,
    IncompleteObject,
    OutOfMemory,
    NoSpaceLeft,
    NotImplemented,
    EndOfStream,
};

pub const Config = struct {
    core: ?Core,
    extensions: ?Extensions,
    srctree: ?SrcTree,

    pub const Core = struct {
        repositoryformatversion: ?isize,
        filemode: ?bool,
        bare: ?bool,
        logallrefupdates: ?bool,
    };

    pub const Extensions = struct {
        objectformat: ?[]const u8,
    };

    pub const SrcTree = struct {
        pinned: ?bool,
        heatmapexcluded: ?bool,
    };
};

/// on success d becomes owned by the returned Repo and will be closed on
/// a call to raze
pub fn init(d: Dir, io: Io) Error!Repo {
    var repo: Repo = .default;
    repo.dir = d;
    if (d.openFile(io, "./HEAD", .{})) |file| {
        file.close(io);
        repo.bare = true;
    } else |_| {
        if (d.openDir(io, "./.git", .{})) |full| {
            if (full.openFile(io, "./HEAD", .{})) |file| {
                file.close(io);
                repo.dir.close(io);
                repo.dir = full;
            } else |_| return error.NotAGitRepo;
        } else |_| return error.NotAGitRepo;
    }
    repo.objects = Objects.init(repo.dir, io) catch return error.NotAGitRepo;

    return repo;
}

/// Dir name must be relative (probably)
pub fn createNew(chdir: Io.Dir, dir_name: []const u8, a: Allocator, io: Io) !Repo {
    var agent = Agent{ .alloc = a, .cwd = chdir };
    a.free(try agent.initEmpty(dir_name, .{}, io));
    var dir = try chdir.openDir(io, dir_name, .{});
    errdefer dir.close(io);
    return init(dir, io);
}

pub fn loadData(self: *Repo, a: Allocator, io: Io) !void {
    try self.loadConfig(a, io);
    try self.objects.initPacks(a, io);
    try self.loadRefs(a, io);
    try self.loadTags(a, io);
    try self.loadBranches(a, io);
    self.remotes = try loadRemotes(self.config_ini.?, a);
    _ = try self.HEAD(a, io);
}

fn loadConfig(self: *Repo, a: Allocator, io: Io) !void {
    const file = try self.dir.openFile(io, "config", .{});
    defer file.close(io);
    const len = try file.length(io);
    const buffer = try a.alloc(u8, len);
    var reader = file.reader(io, buffer);
    self.config_ini = try .init(&reader.interface, a);
    self.config_ini.?.ptr = buffer;
    self.config = try self.config_ini.?.resolve();
}

fn loadRemotes(cfg: Ini.Config(Config), a: Allocator) ![]Remote {
    var list: ArrayList(Remote) = .empty;
    errdefer list.clearAndFree(a);
    for (0..cfg.ini.ns.len) |i| {
        const ns = cfg.ini.filter("remote", i) orelse break;
        try list.append(a, .{
            .name = try a.dupe(u8, std.mem.trim(u8, ns.name[6..], "' \t\n\"")),
            .url = if (ns.get("url")) |url| try a.dupe(u8, url) else null,
            .fetch = if (ns.get("fetch")) |fetch| try a.dupe(u8, fetch) else null,
        });
    }

    return try list.toOwnedSlice(a);
}

pub fn findRemote(self: Repo, name: []const u8) ?Remote {
    for (self.remotes orelse unreachable) |remote| {
        if (eql(u8, remote.name, name)) {
            return remote;
        }
    }
    return null;
}

pub fn loadBlob(repo: Repo, sha: Sha, a: Allocator, io: Io) !Blob {
    return switch (try repo.objects.load(sha, a, io)) {
        .blob => |b| b,
        else => error.NotABlob,
    };
}

pub fn loadRefs(self: *Repo, a: Allocator, io: Io) !void {
    var list: std.ArrayList(Ref) = .empty;
    if (self.dir.openDir(io, "refs/remotes/upstream", .{ .iterate = true })) |*ndir| {
        defer ndir.close(io);
        var itr = ndir.iterate();
        while (try itr.next(io)) |file| {
            if (file.kind != .file) continue;
            var f_b: [2048]u8 = @splat(0);
            const fname: []u8 = try bufPrint(&f_b, "./refs/remotes/upstream/{s}", .{file.name});
            var f = self.dir.openFile(io, fname, .{}) catch continue;
            defer f.close(io);
            // surely enough for sha-50 right?
            var buf: [256]u8 = undefined;
            var reader = f.reader(io, &buf);
            const sha_txt = try reader.interface.takeDelimiter('\n') orelse continue;
            // TODO FIXME
            if (find(u8, sha_txt, "ref: ")) |_| continue;
            const sha: Sha = .init(sha_txt);
            try list.append(a, Ref{ .branch = .{
                .name = try a.dupe(u8, file.name),
                .sha = sha,
            } });
        }
    } else |_| {}

    // TODO walk refs/
    var ndir = try self.dir.openDir(io, "refs/heads", .{ .iterate = true });
    defer ndir.close(io);
    var itr = ndir.iterate();
    while (try itr.next(io)) |file| {
        if (file.kind != .file) continue;
        var f_b: [2048]u8 = @splat(0);
        const fname: []u8 = try bufPrint(&f_b, "./refs/heads/{s}", .{file.name});
        var f = try self.dir.openFile(io, fname, .{});
        defer f.close(io);
        // surely enough for sha-50 right?
        var buf: [256]u8 = undefined;
        var reader = f.reader(io, &buf);
        try list.append(a, Ref{ .branch = .{
            .name = try a.dupe(u8, file.name),
            .sha = .init(try reader.interface.takeDelimiter('\n') orelse continue),
        } });
    }

    if (self.dir.openFile(io, "packed-refs", .{})) |*fd| {
        defer fd.close(io);
        var buf: [2048]u8 = undefined;
        var r = fd.reader(io, &buf);
        while (r.interface.takeSentinel('\n')) |line| {
            if (find(u8, line, " refs/heads")) |i| {
                try list.append(a, Ref{ .branch = .{
                    .name = try a.dupe(u8, line[i + 12 ..]),
                    .sha = Sha.init(line[0..i]),
                } });
            }
        } else |e| switch (e) {
            error.EndOfStream => {},
            else => return e,
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.print("unable to read packed ref {}\n", .{err}),
    }
    self.refs = try list.toOwnedSlice(a);
}

/// TODO write the real function that goes here
pub fn ref(self: Repo, str: []const u8) !Sha {
    const target = cutPrefix(u8, str, "refs/heads/") orelse str;
    for (self.refs) |r| {
        switch (r) {
            .sha => |s| return s,
            .tag => @panic("not implemented"),
            .branch => |b| if (eql(u8, b.name, target)) return b.sha,
            .missing => return error.EmptyRef,
        }
    }
    return error.RefMissing;
}

pub fn resolve(self: Repo, r: Ref) !Sha {
    switch (r) {
        .tag => unreachable,
        .branch => |b| return try self.ref(b.name),
    }
}

/// TODO I don't want this to take an allocator :(
/// Warning, has side effects!
pub fn HEAD(self: *Repo, a: Allocator, io: Io) !Ref {
    var f = try self.dir.openFile(io, "HEAD", .{});
    defer f.close(io);
    var buff: [0xFF]u8 = undefined;

    const size = (try f.stat(io)).size;
    var reader = f.reader(io, &buff);
    try reader.interface.fill(size);
    const head = buff[0..size];

    if (std.mem.eql(u8, head[0..5], "ref: ")) {
        self.head = Ref{
            .branch = Branch{
                .sha = self.ref(head[16 .. head.len - 1]) catch Sha.init(&[_]u8{0} ** 20),
                .name = try a.dupe(u8, head[5 .. head.len - 1]),
            },
        };
    } else if (head.len == 41 and head[40] == '\n') {
        self.head = Ref{
            .sha = Sha.init(head[0..40]), // We don't want that \n char
        };
    } else {
        std.debug.print("unexpected HEAD {s}\n", .{head});
        unreachable;
    }
    return self.head.?;
}

fn loadTags(self: *Repo, a: Allocator, io: Io) !void {
    const fd = self.dir.openFile(io, "packed-refs", .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            std.debug.print("packed-refs {any}\n", .{err});
            @panic("unimplemented error in tags packed-refs");
        },
    };
    defer if (fd) |f| f.close(io);

    const pk_refs: ?[]const u8 = if (fd) |f|
        system.mmap(f.handle, (try f.stat(io)).size, .{}) catch null
    else
        null;

    defer if (pk_refs) |pr| system.munmap(@alignCast(pr));

    const count: usize = if (pk_refs) |p| std.mem.count(u8, p, "refs/tags/") else 0;
    var tags: std.ArrayListUnmanaged(Tag) = try .initCapacity(a, count);
    errdefer tags.deinit(a);

    if (pk_refs) |pkrefs| {
        var lines = splitScalar(u8, pkrefs, '\n');
        while (lines.next()) |line| {
            if (find(u8, line, "refs/tags/")) |i| {
                const name = line[i + 10 ..];

                try tags.append(a, try .fromObject(
                    try self.objects.load(.init(line[0..40]), a, io),
                    try a.dupe(u8, name),
                ));
            }
        }
    }

    var newdir = try self.dir.openDir(io, "refs/tags", .{ .iterate = true });
    defer newdir.close(io);
    var itr = newdir.iterate();

    while (try itr.next(io)) |next| {
        if (next.kind != .file) continue;
        var fnbuf: [2048]u8 = undefined;
        const fname = try bufPrint(&fnbuf, "refs/tags/{s}", .{next.name});

        var conbuf: [44]u8 = undefined;
        const contents = self.dir.readFile(io, fname, &conbuf) catch |err| {
            std.debug.print("unexpected tag format for {s}\n", .{fname});
            return err;
        };
        if (contents.len != 41) {
            std.debug.print("unexpected tag format for {s}\n", .{fname});
            return error.InvalidTagFound;
        }
        try tags.append(a, try .fromObject(
            try self.objects.load(.init(contents[0..40]), a, io),
            try a.dupe(u8, next.name),
        ));
    }
    if (tags.items.len > 0) self.tags = try tags.toOwnedSlice(a);
}

pub fn loadBranchesFrom(self: *Repo, prefix: []const u8, a: Allocator, io: Io) ![]Branch {
    var dir = self.dir.openDir(io, prefix, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.BranchRefMissing,
        else => return err,
    };
    defer dir.close(io);
    var list: ArrayList(Branch) = .empty;
    var itr = dir.iterate();
    while (try itr.next(io)) |file| {
        if (file.kind != .file) continue;
        var fnbuf: [2048]u8 = undefined;
        const fname = try bufPrint(&fnbuf, "{s}/{s}", .{ prefix, file.name });
        var shabuf: [265]u8 = undefined;
        const text = try self.dir.readFile(io, fname, &shabuf);
        if (cutPrefix(u8, text, "ref: ")) |txt| {
            //TODO append non-commits
            log.warn("skipped branch ref: {s}", .{txt});
            continue;
        }
        if (findScalar(u8, text, '\n')) |n| try list.append(a, .{
            .name = try a.dupe(u8, file.name),
            .sha = Sha.init(text[0..n]),
        });
    }

    if (self.dir.openFile(io, "packed-refs", .{})) |*fd| {
        defer fd.close(io);
        var buf: [2048]u8 = undefined;
        var r = fd.reader(io, &buf);
        while (r.interface.takeSentinel('\n')) |line| {
            if (find(u8, line, prefix)) |i| {
                const idx = i + prefix.len + 1;
                try list.append(a, .{
                    .name = try a.dupe(u8, line[idx..]),
                    .sha = Sha.init(line[0 .. i - 1]),
                });
            }
        } else |e| switch (e) {
            error.EndOfStream => {},
            else => return e,
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.print("unable to read packed ref {}\n", .{err}),
    }

    return try list.toOwnedSlice(a);
}

fn loadBranches(r: *Repo, a: Allocator, io: Io) !void {
    r.branches = try r.loadBranchesFrom("refs/heads", a, io);
}

pub fn commit(self: *const Repo, sha: Sha, a: Allocator, io: Io) !Commit {
    if (sha.hash == .partial) {
        const full_sha = try self.objects.resolveSha(sha, io);
        return switch (try self.objects.load(full_sha, a, io)) {
            .commit => |c| {
                var cmt = c;
                cmt.sha = full_sha;
                return cmt;
            },
            else => error.NotACommit,
        };
    } else return switch (try self.objects.load(sha, a, io)) {
        .commit => |c| c,
        else => error.NotACommit,
    };
}

pub fn headCommit(self: *const Repo, a: Allocator, io: Io) !Commit {
    const resolv: Sha = try self.headSha(io);
    return try self.commit(resolv, a, io);
}

pub fn headSha(self: *const Repo, io: Io) !Sha {
    var f = try self.dir.openFile(io, "HEAD", .{});
    defer f.close(io);
    var buff: [0xFF]u8 = undefined;

    var reader = f.reader(io, &buff);
    const head = try reader.interface.takeDelimiter('\n') orelse {
        log.err("Head Sha failed '{s}'\n", .{reader.interface.buffered()});
        return error.RefParseFailed;
    };

    if (cutPrefix(u8, head, "ref: refs/heads/")) |branch| {
        return self.ref(branch) catch {
            log.err("Head Sha failed '{s}'", .{branch});
            return error.RefParseFailed;
        };
    } else if (cutPrefix(u8, head, "ref: refs/remotes/")) |remote_up| {
        return self.ref(remote_up) catch {
            log.err("Head Sha failed '{s}'", .{remote_up});
            return error.RefParseFailed;
        };
    } else if (cutPrefix(u8, head, "ref: refs/")) |bonus_branch| {
        log.err("Bonus branch not implemented yet '{s}'", .{bonus_branch});
        return error.NotImplemented;
    } else if (head.len == 40) {
        return .init(head[0..40]);
    } else if (head.len == 64) {
        return .init(head[0..64]);
    } else {
        log.err("unexpected HEAD '{s}'\n", .{head});
        return error.RefParseFailed;
    }
}

pub fn blob(self: Repo, sha: Sha, a: Allocator, io: Io) !Blob {
    return try self.loadBlob(sha, a, io);
}

pub fn description(self: Repo, a: Allocator, io: Io) ![]u8 {
    if (self.dir.openFile(io, "description", .{})) |*file| {
        defer file.close(io);
        var buf: [0x400]u8 = undefined;
        var reader = file.reader(io, &buf);
        try reader.interface.fillMore();
        const desc = trim(u8, try reader.interface.takeDelimiterExclusive('\n'), " \n\r\t");

        if (find(u8, desc, "Unnamed repository; edit this file") != null)
            return error.DefaultDescription;
        return try a.dupe(u8, desc);
    } else |_| return error.NoDescription;
}

pub fn raze(self: *Repo, a: Allocator, io: Io) void {
    self.dir.close(io);
    if (self.config_ini) |cfg| {
        a.free(cfg.ptr);
        cfg.raze(a);
    }

    self.objects.raze(a, io);

    for (self.refs) |r| switch (r) {
        .branch => |b| {
            a.free(b.name);
        },
        else => unreachable,
    };
    a.free(self.refs);

    if (self.current) |c| a.free(c);
    if (self.head) |h| switch (h) {
        .branch => |b| a.free(b.name),
        else => {}, //a.free(h);
    };
    if (self.branches) |branches| {
        for (branches) |branch| branch.raze(a);
        a.free(branches);
    }
    if (self.remotes) |remotes| {
        for (remotes) |remote| remote.raze(a);
        a.free(remotes);
    }

    if (self.tags) |tags| {
        for (tags) |tag| tag.raze(a);
        a.free(tags);
    }
}

// functions that might move or be removed...

pub fn updatedAt(self: *const Repo, a: Allocator, io: Io) !i64 {
    var oldest: i64 = 0;
    for (self.refs) |r| {
        switch (r) {
            .branch => |br| {
                const cmt = try br.toCommit(self, a, io);
                defer cmt.raze(a);
                if (cmt.committer.timestamp > oldest) oldest = cmt.committer.timestamp;
            },
            else => unreachable, // not implemented... sorry :/
        }
    }
    return oldest;
}

pub fn getAgent(self: *const Repo, a: Allocator) Agent {
    // FIXME if (!self.bare) provide_working_dir_to_git
    return .{
        .alloc = a,
        .repo = self,
        .cwd = self.dir,
    };
}

test Repo {
    _ = &Objects;
}

const Agent = @import("agent.zig");
const Blob = @import("blob.zig");
const Branch = @import("Branch.zig");
const Commit = @import("Commit.zig");
const Objects = @import("Objects.zig");
const Object = Objects.Any;
const Ref = @import("../git.zig").Ref;
const Remote = @import("remote.zig");
const Sha = @import("Sha.zig");
const Tag = @import("Tag.zig");
const Tree = @import("tree.zig");

const Ini = @import("../ini.zig");
const system = @import("../system.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Reader = Io.Reader;
const Dir = Io.Dir;
const log = std.log.scoped(.git_repo);
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;
const eql = std.mem.eql;
const endsWith = std.mem.endsWith;
const find = std.mem.find;
const findScalar = std.mem.findScalar;
const zlib = std.compress.flate;
const bufPrint = std.fmt.bufPrint;
const cutPrefix = std.mem.cutPrefix;
const trim = std.mem.trim;
