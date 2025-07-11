alloc: ?Allocator = null,
bare: bool,
dir: std.fs.Dir,
packs: []Pack,
refs: []Ref,
current: ?[]u8 = null,
head: ?Ref = null,
// Leaks, badly
tags: ?[]Tag = null,
branches: ?[]Branch = null,
remotes: ?[]Remote = null,
config: ?Ini.Config(void) = null,
config_data: ?[]u8 = null,

repo_name: ?[]const u8 = null,

const Repo = @This();

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
pub fn init(d: std.fs.Dir) Error!Repo {
    var repo = initDefaults();
    repo.dir = d;
    if (d.openFile("./HEAD", .{})) |file| {
        file.close();
        repo.bare = true;
    } else |_| {
        if (d.openDir("./.git", .{})) |full| {
            if (full.openFile("./HEAD", .{})) |file| {
                file.close();
                repo.dir.close();
                repo.dir = full;
            } else |_| return error.NotAGitRepo;
        } else |_| return error.NotAGitRepo;
    }

    return repo;
}

fn initDefaults() Repo {
    return Repo{
        .bare = false,
        .dir = undefined,
        .packs = &[0]Pack{},
        .refs = &[0]Ref{},
    };
}

/// Dir name must be relative (probably)
pub fn createNew(a: Allocator, chdir: std.fs.Dir, dir_name: []const u8) !Repo {
    var agent = Agent{
        .alloc = a,
        .cwd = chdir,
    };

    a.free(try agent.initRepo(dir_name, .{}));
    var dir = try chdir.openDir(dir_name, .{});
    errdefer dir.close();
    return init(dir);
}

pub fn loadData(self: *Repo, a: Allocator) !void {
    if (self.alloc != null) unreachable;
    self.alloc = a;

    try self.loadConfig();
    try self.loadPacks();
    try self.loadRefs();
    try self.loadTags();
    try self.loadBranches();
    try self.loadRemotes();
    _ = try self.HEAD(a);
}

fn loadConfig(self: *Repo) !void {
    self.config_data = try self.dir.readFileAlloc(self.alloc.?, "config", 0xffff);
    self.config = try .init(self.alloc.?, self.config_data.?);
}

fn loadRemotes(self: *Repo) !void {
    const a = self.alloc orelse unreachable;
    var list = std.ArrayList(Remote).init(a);
    errdefer list.clearAndFree();
    const cfg = self.config orelse return;
    for (0..cfg.ctx.ns.len) |i| {
        const ns = cfg.ctx.filter("remote", i) orelse break;
        try list.append(.{
            .name = try a.dupe(u8, std.mem.trim(u8, ns.name[6..], "' \t\n\"")),
            .url = if (ns.get("url")) |url| try a.dupe(u8, url) else null,
            .fetch = if (ns.get("fetch")) |fetch| try a.dupe(u8, fetch) else null,
        });
    }

    self.remotes = try list.toOwnedSlice();
}

pub fn findRemote(self: Repo, name: []const u8) !?*const Remote {
    const remotes = self.remotes orelse unreachable;
    for (remotes) |*remote| {
        if (eql(u8, remote.name, name)) {
            return remote;
        }
    }
    return null;
}

fn loadFile(self: Repo, a: Allocator, sha: SHA) !Object {
    var fb = [_]u8{0} ** 2048;
    const grouped = try bufPrint(&fb, "./objects/{s}/{s}", .{ sha.hex()[0..2], sha.hex()[2..] });
    const compressed: []u8 = self.dir.readFileAlloc(a, grouped, 0xffffff) catch |err| switch (err) {
        error.FileNotFound => data: {
            const exact = try bufPrint(&fb, "./objects/{s}", .{sha.hex()[0..]});
            break :data self.dir.readFileAlloc(a, exact, 0xffffff) catch |err2| switch (err2) {
                error.FileNotFound => {
                    std.debug.print("unable to find commit '{s}'\n", .{sha.hex()[0..]});
                    return error.ObjectMissing;
                },
                else => return err2,
            };
        },
        else => return err,
    };
    defer a.free(compressed);
    var fbs = std.io.fixedBufferStream(compressed);
    const fbsr = fbs.reader();
    var decom = zlib.decompressor(fbsr);
    const decomr = decom.reader();
    const data = try decomr.readAllAlloc(a, 0xffffff);
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

fn loadPacked(self: Repo, a: Allocator, sha: SHA) !?Object {
    for (self.packs) |pack| {
        if (pack.contains(sha)) |offset| {
            return try pack.resolveObject(sha, a, offset, &self);
        }
    }
    return null;
}

fn loadPackedPartial(self: Repo, a: Allocator, sha: SHA) !?Object {
    //std.debug.assert(sha.partial == true);
    for (self.packs) |pack| {
        if (try pack.containsPrefix(sha.bin[0..sha.len])) |offset| {
            return try pack.resolveObject(sha, a, offset, &self);
        }
    }
    return null;
}

fn loadPartial(self: Repo, a: Allocator, sha: SHA) !Pack.PackedObject {
    if (try self.loadPackedPartial(a, sha)) |pack| return pack;
    return error.ObjectMissing;
}

fn loadObjectPartial(self: Repo, a: Allocator, sha: SHA) !?Object {
    //std.debug.assert(sha.partial);
    if (try self.loadPackedPartial(a, sha)) |pack| return pack;
    return null;
}

pub fn loadObjectOrDelta(self: Repo, a: Allocator, sha: SHA) !union(enum) {
    pack: Pack.PackedObject,
    file: Object,
} {
    for (self.packs) |pack| {
        if (pack.contains(sha)) |offset| {
            return .{ .pack = try pack.loadData(a, offset, &self) };
        }
    }
    return .{ .file = try self.loadFile(a, sha) };
}

/// TODO binary search lol
pub fn loadObject(self: Repo, a: Allocator, sha: SHA) !Object {
    if (sha.partial) return try self.loadObjectPartial(a, sha) orelse error.ObjectMissing;
    return try self.loadPacked(a, sha) orelse try self.loadFile(a, sha);
}

pub fn loadBlob(self: Repo, a: Allocator, sha: SHA) !Blob {
    return switch (try self.loadObject(a, sha)) {
        .blob => |b| b,
        else => error.NotABlob,
    };
}

pub fn loadPacks(self: *Repo) !void {
    const a = self.alloc orelse unreachable;
    var dir = try self.dir.openDir("./objects/pack", .{ .iterate = true });
    defer dir.close();
    var itr = dir.iterate();
    var i: usize = 0;
    while (try itr.next()) |file| {
        if (!std.mem.eql(u8, file.name[file.name.len - 4 ..], ".idx")) continue;
        i += 1;
    }
    self.packs = try a.alloc(Pack, i);
    itr.reset();
    i = 0;
    while (try itr.next()) |file| {
        if (!std.mem.eql(u8, file.name[file.name.len - 4 ..], ".idx")) continue;

        self.packs[i] = try Pack.init(dir, file.name[0 .. file.name.len - 4]);
        i += 1;
    }
}

pub fn loadRefs(self: *Repo) !void {
    const a = self.alloc orelse unreachable;
    var list = std.ArrayList(Ref).init(a);
    var idir = try self.dir.openDir("refs/heads", .{ .iterate = true });
    defer idir.close();
    var itr = idir.iterate();
    while (try itr.next()) |file| {
        if (file.kind != .file) continue;
        var filename = [_]u8{0} ** 2048;
        var fname: []u8 = &filename;
        fname = try std.fmt.bufPrint(&filename, "./refs/heads/{s}", .{file.name});
        var f = try self.dir.openFile(fname, .{});
        defer f.close();
        var buf: [40]u8 = undefined;
        const read = try f.readAll(&buf);
        std.debug.assert(read == 40);
        try list.append(Ref{ .branch = .{
            .name = try a.dupe(u8, file.name),
            .sha = SHA.init(&buf),
            .repo = self,
        } });
    }
    var buf: [2048]u8 = undefined;
    if (self.dir.readFile("packed-refs", &buf)) |b| {
        var p_itr = splitScalar(u8, b, '\n');
        _ = p_itr.next();
        while (p_itr.next()) |line| {
            if (std.mem.indexOf(u8, line, "refs/heads")) |_| {
                try list.append(Ref{ .branch = .{
                    .name = try a.dupe(u8, line[52..]),
                    .sha = SHA.init(line[0..40]),
                    .repo = self,
                } });
            }
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => std.debug.print("unable to read packed ref {}\n", .{err}),
    }
    self.refs = try list.toOwnedSlice();
}

/// TODO write the real function that goes here
pub fn ref(self: Repo, str: []const u8) !SHA {
    for (self.refs) |r| {
        switch (r) {
            .sha => |s| return s,
            .tag => unreachable,
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
pub fn HEAD(self: *Repo, a: Allocator) !Ref {
    var f = try self.dir.openFile("HEAD", .{});
    defer f.close();
    var buff: [0xFF]u8 = undefined;

    const size = try f.read(&buff);
    const head = buff[0..size];

    if (std.mem.eql(u8, head[0..5], "ref: ")) {
        self.head = Ref{
            .branch = Branch{
                .sha = self.ref(head[16 .. head.len - 1]) catch SHA.init(&[_]u8{0} ** 20),
                .name = try a.dupe(u8, head[5 .. head.len - 1]),
                .repo = self,
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

fn loadTags(self: *Repo) !void {
    const a = self.alloc orelse return error.InvalidRepoState;

    const fd = self.dir.openFile("packed-refs", .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            std.debug.print("packed-refs {any}\n", .{err});
            @panic("unimplemented error in tags packed-refs");
        },
    };

    const pk_refs: ?[]const u8 = if (fd) |f|
        system.mmap(f.handle, try f.getEndPos(), .{}) catch null
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
                    try self.loadObject(a, .init(line[0..40])),
                    try a.dupe(u8, name),
                ));
            }
        }
    }

    var tagdir = try self.dir.openDir("refs/tags", .{ .iterate = true });
    defer tagdir.close();
    var itr = tagdir.iterate();

    while (try itr.next()) |next| {
        if (next.kind != .file) continue;
        var fnbuf: [2048]u8 = undefined;
        const fname = try bufPrint(&fnbuf, "refs/tags/{s}", .{next.name});

        var conbuf: [44]u8 = undefined;
        const contents = self.dir.readFile(fname, &conbuf) catch |err| {
            std.debug.print("unexpected tag format for {s}\n", .{fname});
            return err;
        };
        if (contents.len != 41) {
            std.debug.print("unexpected tag format for {s}\n", .{fname});
            return error.InvalidTagFound;
        }
        try tags.append(a, try .fromObject(
            try self.loadObject(a, .init(contents[0..40])),
            try a.dupe(u8, next.name),
        ));
    }
    if (tags.items.len > 0) self.tags = try tags.toOwnedSlice(a);
}

fn loadBranches(self: *Repo) !void {
    const a = self.alloc orelse unreachable;

    var branchdir = try self.dir.openDir("refs/heads", .{ .iterate = true });
    defer branchdir.close();
    var list = std.ArrayList(Branch).init(a);
    var itr = branchdir.iterate();
    while (try itr.next()) |file| {
        if (file.kind != .file) continue;
        var fnbuf: [2048]u8 = undefined;
        const fname = try bufPrint(&fnbuf, "refs/heads/{s}", .{file.name});
        var shabuf: [41]u8 = undefined;
        _ = try self.dir.readFile(fname, &shabuf);
        try list.append(.{
            .name = try a.dupe(u8, file.name),
            .sha = SHA.init(shabuf[0..40]),
            .repo = self,
        });
    }
    self.branches = try list.toOwnedSlice();
}

pub fn resolvePartial(repo: *const Repo, sha: SHA) !?SHA {
    if (!sha.partial) return sha;
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

pub fn commit(self: *const Repo, a: Allocator, sha: SHA) !Commit {
    if (sha.partial) {
        const full_sha = try self.resolvePartial(sha) orelse sha; //unreachable;
        return switch (try self.loadObjectPartial(a, sha) orelse
            try self.loadObject(a, full_sha)) {
            .commit => |c| {
                var cmt = c;
                cmt.sha = full_sha;
                return cmt;
            },
            else => error.NotACommit,
        };
    } else return switch (try self.loadObject(a, sha)) {
        .commit => |c| c,
        else => error.NotACommit,
    };
}

pub fn headCommit(self: *const Repo, a: Allocator) !Commit {
    const resolv: SHA = try self.headSha();
    return try self.commit(a, resolv);
}

pub fn headSha(self: *const Repo) !SHA {
    return switch (self.head.?) {
        .sha => |s| s,
        .branch => |b| try self.ref(b.name["refs/heads/".len..]),
        .tag => return error.CommitMissing,
        .missing => return error.CommitMissing,
    };
}

pub fn blob(self: Repo, a: Allocator, sha: SHA) !Blob {
    return try self.loadBlob(a, sha);
}

pub fn description(self: Repo, a: Allocator) ![]u8 {
    if (self.dir.openFile("description", .{})) |*file| {
        defer file.close();
        return try file.readToEndAlloc(a, 0xFFFF);
    } else |_| {}
    return error.NoDescription;
}

pub fn raze(self: *Repo) void {
    self.dir.close();
    if (self.alloc) |a| {
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
}

// functions that might move or be removed...

pub fn updatedAt(self: *const Repo, a: Allocator) !i64 {
    var oldest: i64 = 0;
    for (self.refs) |r| {
        switch (r) {
            .branch => |br| {
                const cmt = try br.toCommit(a);
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
        .cwd = self.dir,
    };
}

test "hopefully a delta" {
    const a = std.testing.allocator;
    var cwd = std.fs.cwd();
    const dir = try cwd.openDir("repos/hastur", .{});
    var repo = try Repo.init(dir);
    try repo.loadData(a);
    defer repo.raze();

    var head = try repo.headCommit(a);
    defer head.raze();
    if (false) std.debug.print("{}\n", .{head});

    const obj = try repo.loadPacked(a, head.tree) orelse return error.UnableToLoadObject;
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
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const zlib = std.compress.zlib;
const bufPrint = std.fmt.bufPrint;
