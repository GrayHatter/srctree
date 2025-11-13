bare: bool,
dir: Dir,
packs: []Pack,
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
    .packs = &[0]Pack{},
    .refs = &[0]Ref{},
};

pub const Error = error{
    ReadError,
    NotAGitRepo,
    RefMissing,
    CommitMissing,
    InvalidCommit,
    BlobMissing,
    TreeMissing,
    InvalidTree,
    ObjectMissing,
    IncompleteObject,
    OutOfMemory,
    NoSpaceLeft,
    NotImplemented,
    EndOfStream,
    PackCorrupt,
    PackRef,
    AmbiguousRef,
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
    try self.loadPacks(a, io);
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

fn loadFile(self: Repo, sha: SHA, a: Allocator, io: Io) !Object {
    var fb = [_]u8{0} ** 2048;
    const grouped = try bufPrint(&fb, "./objects/{s}/{s}", .{ sha.hex()[0..2], sha.hex()[2..] });
    const file = self.dir.openFile(io, grouped, .{}) catch |err| switch (err) {
        error.FileNotFound => data: {
            const exact = try bufPrint(&fb, "./objects/{s}", .{sha.hex()[0..]});
            break :data self.dir.openFile(io, exact, .{}) catch |err2| switch (err2) {
                error.FileNotFound => {
                    std.debug.print("unable to find commit '{s}'\n", .{sha.hex()[0..]});
                    return error.ObjectMissing;
                },
                else => return err2,
            };
        },
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    const compressed: []u8 = try a.alloc(u8, stat.size);
    defer a.free(compressed);
    var reader = file.reader(io, compressed);
    var z_b: [zlib.max_window_len * 2]u8 = undefined;
    var zl: std.compress.flate.Decompress = .init(&reader.interface, .zlib, &z_b);
    const data = try zl.reader.allocRemaining(a, .limited(0xffffff));
    errdefer a.free(data);
    if (indexOf(u8, data, "\x00")) |i| {
        const header = data[0..i];
        _ = header;
        const body = data[i + 1 ..];
        if (startsWith(u8, data, "blob ")) {
            return .{ .blob = .initOwned(sha, @splat(0xff), body, body, data) };
        } else if (startsWith(u8, data, "tree ")) {
            return .{ .tree = try .initOwned(sha, a, body, data) };
        } else if (startsWith(u8, data, "commit ")) {
            return .{ .commit = try .initOwned(sha, a, body, data) };
        } else if (startsWith(u8, data, "tag ")) {
            return .{ .tag = try .initOwned(sha, body) };
        }
    }
    return error.InvalidObject;
}

fn loadPacked(self: Repo, sha: SHA, a: Allocator, io: Io) !?Object {
    for (self.packs) |pack| {
        if (pack.contains(sha)) |offset| {
            return try pack.resolveObject(sha, offset, &self, a, io);
        }
    }
    return null;
}

fn loadPackedPartial(self: Repo, sha: SHA, a: Allocator, io: Io) !?Object {
    for (self.packs) |pack| {
        if (try pack.containsPrefix(sha.bin[0..sha.len])) |offset| {
            return try pack.resolveObject(sha, offset, &self, a, io);
        }
    }
    return null;
}

fn loadObjectPartial(self: Repo, sha: SHA, a: Allocator, io: Io) !?Object {
    if (try self.loadPackedPartial(sha, a, io)) |pack| return pack;
    return null;
}

pub fn loadObjectOrDelta(self: Repo, sha: SHA, a: Allocator, io: Io) !union(enum) {
    pack: Pack.PackedObject,
    file: Object,
} {
    for (self.packs) |pack| {
        if (pack.contains(sha)) |offset| {
            return .{ .pack = try pack.loadData(offset, &self, a, io) };
        }
    }
    return .{ .file = try self.loadFile(sha, a, io) };
}

/// TODO binary search lol
pub fn loadObject(self: Repo, sha: SHA, a: Allocator, io: Io) !Object {
    if (sha.len < 20) return try self.loadObjectPartial(sha, a, io) orelse error.ObjectMissing;
    return try self.loadPacked(sha, a, io) orelse try self.loadFile(sha, a, io);
}

pub fn loadBlob(self: Repo, sha: SHA, a: Allocator, io: Io) !Blob {
    return switch (try self.loadObject(sha, a, io)) {
        .blob => |b| b,
        else => error.NotABlob,
    };
}

pub fn loadPacks(self: *Repo, a: Allocator, io: Io) !void {
    var dir = try self.dir.openDir(io, "./objects/pack", .{ .iterate = true });
    defer dir.close(io);
    self.packs = try Pack.initAllFromDir(dir, a, io);
}

pub fn loadRefs(self: *Repo, a: Allocator, io: Io) !void {
    var list: std.ArrayList(Ref) = .{};
    var ndir = try self.dir.openDir(io, "refs/heads", .{ .iterate = true });
    defer ndir.close(io);
    var idir: fs.Dir = .adaptFromNewApi(ndir);
    var itr = idir.iterate();
    while (try itr.next()) |file| {
        if (file.kind != .file) continue;
        var filename = [_]u8{0} ** 2048;
        var fname: []u8 = &filename;
        fname = try std.fmt.bufPrint(&filename, "./refs/heads/{s}", .{file.name});
        var f = try self.dir.openFile(io, fname, .{});
        defer f.close(io);
        var buf: [40]u8 = undefined;
        var reader = f.reader(io, &buf);
        try reader.interface.fill(40);
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
                    try self.loadObject(.init(line[0..40]), a, io),
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
            try self.loadObject(.init(contents[0..40]), a, io),
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

pub fn resolvePartial(repo: *const Repo, sha: SHA) !?SHA {
    if (sha.len == 20) return sha;
    if (sha.len < 3) return error.TooShort; // not supported

    var ambiguous: bool = false;
    for (repo.packs) |pack| {
        if (pack.expandPrefix(sha) catch |err| switch (err) {
            error.AmbiguousRef => {
                ambiguous = true;
                continue;
            },
            else => return err,
        }) |s| {
            return s;
        }
    }
    if (ambiguous) return error.AmbiguousRef;
    return null;
}

pub fn commit(self: *const Repo, sha: SHA, a: Allocator, io: Io) !Commit {
    if (sha.len < 20) {
        const full_sha = try self.resolvePartial(sha) orelse sha; //unreachable;
        return switch (try self.loadObjectPartial(sha, a, io) orelse
            try self.loadObject(full_sha, a, io)) {
            .commit => |c| {
                var cmt = c;
                cmt.sha = full_sha;
                return cmt;
            },
            else => error.NotACommit,
        };
    } else return switch (try self.loadObject(sha, a, io)) {
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

    for (self.packs) |pack| {
        pack.raze();
    }
    a.free(self.packs);
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

test "hopefully a delta" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.fs.cwd();
    const dir = try cwd.openDir("repos/hastur", .{});
    var repo = try Repo.init(dir.adaptToNewApi(), io);
    try repo.loadData(a, io);
    defer repo.raze(a, io);

    var head = try repo.headCommit(a, io);
    defer head.raze();
    if (false) std.debug.print("{}\n", .{head});

    const obj = try repo.loadPacked(head.tree, a, io) orelse return error.UnableToLoadObject;
    switch (obj) {
        .tree => |tree| tree.raze(),
        else => return error.NotATree,
    }
    if (false) std.debug.print("{}\n", .{obj.tree});
}

const Agent = @import("agent.zig");
const Blob = @import("blob.zig");
const Branch = @import("Branch.zig");
const Commit = @import("Commit.zig");
const Object = @import("Object.zig").Object;
const Pack = @import("pack.zig");
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
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;
const eql = std.mem.eql;
const endsWith = std.mem.endsWith;
const indexOf = std.mem.indexOf;
const zlib = std.compress.flate;
const bufPrint = std.fmt.bufPrint;
