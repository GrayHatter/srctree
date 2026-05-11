bare: bool,
dir: Dir,
objects: Objects,
refs: RefMap = .empty,
current: ?[]u8 = null,
remotes: StringArrayHashMap(Remote) = .empty,
config: ?Ini.Config(Config).Base = null,
config_ini: ?Ini.Config(Config) = null,
repo_name: ?[]const u8 = null,

const Repo = @This();

pub const RefMap = StringArrayHashMap(Ref);

pub const default: Repo = .{
    .bare = false,
    .dir = undefined,
    .objects = undefined,
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
    var git_agent: Agent = .{ .alloc = a, .cwd = chdir };
    a.free(try git_agent.initEmpty(dir_name, .{}, io));
    var dir = try chdir.openDir(io, dir_name, .{});
    errdefer dir.close(io);
    return init(dir, io);
}

pub fn loadData(self: *Repo, a: Allocator, io: Io) !void {
    try self.loadConfig(a, io);
    try self.objects.initPacks(a, io);
    try self.loadRefs(a, io);
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

pub fn findRemote(self: *const Repo, name: []const u8) ?Remote {
    return self.remotes.get(name);
}

pub fn loadBlob(repo: Repo, sha: Sha, a: Allocator, io: Io) !Blob {
    return switch (try repo.objects.load(sha, a, io)) {
        .blob => |b| b,
        else => error.NotABlob,
    };
}

fn addRemote(repo: *Repo, ref_name: []const u8, sha_txt: []const u8, a: Allocator) !void {
    const remotes = &repo.remotes;
    const remote, const branch_str = std.mem.cut(u8, ref_name, "/") orelse return error.BadRemoteName;
    const gop = try remotes.getOrPut(a, remote);
    if (!gop.found_existing) {
        gop.key_ptr.* = try a.dupe(u8, remote);
        gop.value_ptr.* = .{
            .name = gop.key_ptr.*,
            .url = null,
            .fetch = null,
        };
    }
    const branch = try a.dupe(u8, branch_str);
    if (try gop.value_ptr.refs.fetchPut(a, branch, .{ .sha = .init(sha_txt) })) |_| {
        a.free(branch);
    }
}

pub fn loadRefs(self: *Repo, a: Allocator, io: Io) !void {
    const local: *RefMap = &self.refs;
    if (self.dir.openFile(io, "packed-refs", .{})) |*fd| {
        defer fd.close(io);
        var buf: [2048]u8 = undefined;
        var r = fd.reader(io, &buf);
        while (r.interface.takeSentinel('\n')) |line| {
            if (std.mem.cut(u8, line, " refs/heads/")) |cut| {
                const sha, const ref_name = cut;
                const name = try a.dupe(u8, ref_name);
                if (try local.fetchPut(a, name, .{ .sha = .init(sha) })) |_| a.free(name);
            } else if (std.mem.cut(u8, line, " refs/remotes/")) |cut| {
                const sha, const ref_name = cut;
                self.addRemote(ref_name, sha, a) catch return;
            }
        } else |e| switch (e) {
            error.EndOfStream => {},
            else => return e,
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.print("unable to read packed ref {}\n", .{err}),
    }

    if (self.dir.openDir(io, "refs", .{ .iterate = true })) |*ndir| {
        defer ndir.close(io);
        var walker = try ndir.walkSelectively(a);
        defer walker.deinit();
        while (try walker.next(io)) |next| {
            try walker.enter(io, next);
            if (next.kind != .file) continue;
            var f = next.dir.openFile(io, next.basename, .{}) catch continue;
            defer f.close(io);
            // surely enough for sha-50 right?
            var buf: [256]u8 = undefined;
            var reader = f.reader(io, &buf);
            const sha_txt = try reader.interface.takeDelimiter('\n') orelse continue;
            if (cutPrefix(u8, next.path, "remotes/")) |name| {
                if (find(u8, sha_txt, "ref: ")) |_| continue;
                self.addRemote(name, sha_txt, a) catch continue;
            } else if (cutPrefix(u8, next.path, "heads/")) |ref_name| {
                if (find(u8, sha_txt, "ref: ")) |_| continue;
                const sha: Sha = .init(sha_txt);
                const name = try a.dupe(u8, ref_name);
                if (try local.fetchPut(a, name, .{ .sha = sha })) |_|
                    a.free(name);
            } else if (cutPrefix(u8, next.path, "tags/")) |ref_name| {
                if (find(u8, sha_txt, "ref: ")) |_| continue;
                const sha: Sha = .init(sha_txt);
                const name = try a.dupe(u8, ref_name);
                if (try local.fetchPut(a, name, .{ .tag = sha })) |_|
                    a.free(name);
            }
        }
    } else |_| {}

    if (self.dir.openFile(io, "HEAD", .{})) |*f| {
        defer f.close(io);
        var buff: [0xFF]u8 = undefined;

        const size = (try f.stat(io)).size;
        var reader = f.reader(io, &buff);
        try reader.interface.fill(size);
        const head = buff[0..size];

        if (cutPrefix(u8, trimWs(head), "ref: refs/")) |head_str| {
            if (self.ref(head_str)) |found| {
                try local.put(a, try a.dupe(u8, "HEAD"), .{ .sha = found });
            } else |_| try local.put(a, try a.dupe(u8, "HEAD"), .{ .ref = head_str });
        } else {
            try local.put(a, try a.dupe(u8, "HEAD"), .{ .sha = .init(trimWs(head)) });
        }
    } else |_| {}
}

pub fn ref(repo: Repo, str: []const u8) !Sha {
    const target = cutPrefix(u8, str, "refs/") orelse str;
    if (repo.refs.get(target)) |refr| switch (refr) {
        .tag => @panic("not implemented"),
        .sha => |s| return s,
        .ref => |r| {
            std.debug.assert(!eql(u8, str, r));
            return repo.ref(r);
        },
        .pending => unreachable,
    };
    if (cutPrefix(u8, target, "heads/")) |cut| return repo.ref(cut);
    return error.RefMissing;
}

pub fn resolve(self: Repo, r: Ref) !Sha {
    switch (r) {
        .tag => unreachable,
        .branch => |b| return try self.ref(b.name),
    }
}

pub fn HEAD(self: *const Repo, a: Allocator, io: Io) !Commit {
    const sha = self.refs.get("HEAD") orelse return error.CommitInvalid;
    return self.commit(sha.sha, a, io);
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

    for (self.refs.keys(), self.refs.values()) |key, val| switch (val) {
        else => a.free(key),
    };
    self.refs.deinit(a);

    if (self.current) |c| a.free(c);
    for (self.remotes.values()) |*remote| remote.raze(a);
    self.remotes.deinit(a);
}

pub fn agent(self: *const Repo, a: Allocator) Agent {
    // FIXME if (!self.bare) provide_working_dir_to_git
    return .{
        .alloc = a,
        .repo = self,
        .cwd = self.dir,
    };
}

fn trimWs(str: []const u8) []const u8 {
    return std.mem.trim(u8, str, &std.ascii.whitespace);
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
const Remote = @import("Remote.zig");
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
const StringArrayHashMap = std.StringArrayHashMapUnmanaged;
