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
config: ?Ini.Any = null,
config_data: ?[]u8 = null,

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
pub fn createNew(chdir: fs.Dir, dir_name: []const u8, a: Allocator, io: Io) !Repo {
    var agent = Agent{ .alloc = a, .cwd = chdir };
    a.free(try agent.initRepo(dir_name, .{}));
    var dir = try chdir.openDir(dir_name, .{});
    errdefer dir.close();
    return init(dir.adaptToNewApi(), io);
}

pub fn loadData(self: *Repo, a: Allocator, io: Io) !void {
    try self.loadConfig(a, io);
    try self.objects.initPacks(a, io);
    try self.loadRefs(a, io);
    try self.loadTags(a, io);
    try self.loadBranches(a, io);
    self.remotes = try loadRemotes(self.config.?, a);
    _ = try self.HEAD(a, io);
}

fn loadConfig(self: *Repo, a: Allocator, io: Io) !void {
    const file = try self.dir.openFile(io, "config", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    self.config_data = try a.alloc(u8, stat.size);
    var reader = file.reader(io, self.config_data.?);
    try reader.interface.fill(stat.size);
    self.config = try .init(a, self.config_data.?);
}

fn loadRemotes(cfg: Ini.Any, a: Allocator) ![]Remote {
    var list: ArrayList(Remote) = .{};
    errdefer list.clearAndFree(a);
    for (0..cfg.ctx.ns.len) |i| {
        const ns = cfg.ctx.filter("remote", i) orelse break;
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

pub fn loadBlob(repo: Repo, sha: SHA, a: Allocator, io: Io) !Blob {
    return switch (try repo.objects.load(sha, a, io)) {
        .blob => |b| b,
        else => error.NotABlob,
    };
}

pub fn loadRefs(self: *Repo, a: Allocator, io: Io) !void {
    var list: std.ArrayList(Ref) = .{};
    var ndir = try self.dir.openDir(io, "refs/heads", .{ .iterate = true });
    defer ndir.close(io);
    var idir: fs.Dir = .adaptFromNewApi(ndir);
    var itr = idir.iterate();
    while (try itr.next()) |file| {
        if (file.kind != .file) continue;
        var f_b: [2048]u8 = @splat(0);
        const fname: []u8 = try bufPrint(&f_b, "./refs/heads/{s}", .{file.name});
        var f = try self.dir.openFile(io, fname, .{});
        defer f.close(io);
        var buf: [40]u8 = undefined;
        var reader = f.reader(io, &buf);
        reader.interface.fill(40) catch continue;
        std.debug.assert(reader.interface.end == 40);
        try list.append(a, Ref{ .branch = .{
            .name = try a.dupe(u8, file.name),
            .sha = SHA.init(&buf),
        } });
    }
    var buf: [2048]u8 = undefined;
    if (self.dir.readFile(io, "packed-refs", &buf)) |b| {
        var p_itr = splitScalar(u8, b, '\n');
        _ = p_itr.next();
        while (p_itr.next()) |line| {
            if (std.mem.indexOf(u8, line, "refs/heads")) |_| {
                try list.append(a, Ref{ .branch = .{
                    .name = try a.dupe(u8, line[52..]),
                    .sha = SHA.init(line[0..40]),
                } });
            }
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.print("unable to read packed ref {}\n", .{err}),
    }
    self.refs = try list.toOwnedSlice(a);
}

/// TODO write the real function that goes here
pub fn ref(self: Repo, str: []const u8) !SHA {
    for (self.refs) |r| {
        switch (r) {
            .sha => |s| return s,
            .tag => @panic("not implemented"),
            .branch => |b| {
                if (std.mem.eql(u8, b.name, str)) {
                    return b.sha;
                }
            },
            .missing => return error.EmptyRef,
        }
    }
    return error.RefMissing;
}

pub fn resolve(self: Repo, r: Ref) !SHA {
    switch (r) {
        .tag => unreachable,
        .branch => |b| {
            return try self.ref(b.name);
        },
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
                .sha = self.ref(head[16 .. head.len - 1]) catch SHA.init(&[_]u8{0} ** 20),
                .name = try a.dupe(u8, head[5 .. head.len - 1]),
            },
        };
    } else if (head.len == 41 and head[40] == '\n') {
        self.head = Ref{
            .sha = SHA.init(head[0..40]), // We don't want that \n char
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
            if (indexOf(u8, line, "refs/tags/")) |i| {
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
    var tagdir: fs.Dir = .adaptFromNewApi(newdir);
    var itr = tagdir.iterate();

    while (try itr.next()) |next| {
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

fn loadBranches(self: *Repo, a: Allocator, io: Io) !void {
    var newdir = try self.dir.openDir(io, "refs/heads", .{ .iterate = true });
    defer newdir.close(io);
    var list: ArrayList(Branch) = .{};
    var branchdir: fs.Dir = .adaptFromNewApi(newdir);
    var itr = branchdir.iterate();
    while (try itr.next()) |file| {
        if (file.kind != .file) continue;
        var fnbuf: [2048]u8 = undefined;
        const fname = try bufPrint(&fnbuf, "refs/heads/{s}", .{file.name});
        var shabuf: [41]u8 = undefined;
        _ = try self.dir.readFile(io, fname, &shabuf);
        try list.append(a, .{
            .name = try a.dupe(u8, file.name),
            .sha = SHA.init(shabuf[0..40]),
        });
    }
    self.branches = try list.toOwnedSlice(a);
}

pub fn commit(self: *const Repo, sha: SHA, a: Allocator, io: Io) !Commit {
    if (sha.len < 20) {
        const full_sha = try self.objects.resolveSha(sha, io) orelse sha; //unreachable;
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
    const resolv: SHA = try self.headSha();
    return try self.commit(resolv, a, io);
}

pub fn headSha(self: *const Repo) !SHA {
    return switch (self.head.?) {
        .sha => |s| s,
        .branch => |b| try self.ref(b.name["refs/heads/".len..]),
        .tag => return error.CommitMissing,
        .missing => return error.CommitMissing,
    };
}

pub fn blob(self: Repo, sha: SHA, a: Allocator, io: Io) !Blob {
    return try self.loadBlob(sha, a, io);
}

pub fn description(self: Repo, a: Allocator, io: Io) ![]u8 {
    if (self.dir.openFile(io, "description", .{})) |*file| {
        defer file.close(io);
        const stat = try file.stat(io);
        std.debug.assert(stat.size < 0xFFFF);
        const data = try a.alloc(u8, stat.size);
        var reader = file.reader(io, data);
        try reader.interface.fill(stat.size);
        return data;
    } else |_| {}
    return error.NoDescription;
}

pub fn raze(self: *Repo, a: Allocator, io: Io) void {
    self.dir.close(io);
    if (self.config) |cfg| {
        cfg.raze(a);
    }
    if (self.config_data) |cd| {
        a.free(cd);
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
                defer cmt.raze();
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
        .cwd = .adaptFromNewApi(self.dir),
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
const Ref = @import("ref.zig").Ref;
const Remote = @import("remote.zig");
const SHA = @import("SHA.zig");
const Tag = @import("Tag.zig");
const Tree = @import("tree.zig");

const Ini = @import("../ini.zig");
const system = @import("../system.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const fs = std.fs;
const Reader = Io.Reader;
const Dir = Io.Dir;
const log = std.log.scoped(.git_repo);
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;
const eql = std.mem.eql;
const endsWith = std.mem.endsWith;
const indexOf = std.mem.indexOf;
const zlib = std.compress.flate;
const bufPrint = std.fmt.bufPrint;
