pub const Actor = @import("git/actor.zig");
pub const Agent = @import("git/agent.zig");
pub const Blob = @import("git/blob.zig");
pub const Branch = @import("git/Branch.zig");
pub const ChangeSet = @import("git/changeset.zig");
pub const Commit = @import("git/Commit.zig");
pub const Object = @import("git/Object.zig").Object;
pub const Pack = @import("git/pack.zig");
pub const Remote = @import("git/remote.zig");
pub const Repo = @import("git/Repo.zig");
pub const SHA = @import("git/SHA.zig");
pub const Tag = @import("git/Tag.zig");
pub const Tree = @import("git/tree.zig");
pub const Ref = @import("git/ref.zig").Ref;

/// TODO for commitish
/// direct
/// - [x] sha
/// - [ ] refname
/// - [ ] describe output (tag, etc)
/// - [ ] @
/// - [ ] ^
/// - [ ] +
/// - [ ] :
/// range
/// - [ ] ..
/// - [ ] ...
/// - [ ] ^
/// - [ ] ^-
/// - [ ] ^!
///
///
/// Warning only has support for sha currently
pub fn commitish(rev: []const u8) bool {
    if (rev.len < 4 or rev.len > 40) return false;

    for (rev) |c| switch (c) {
        'a'...'f' => continue,
        'A'...'F' => continue,
        '0'...'9' => continue,
        '.' => continue,
        else => return false,
    };
    return true;
}

pub fn commitishRepo(rev: []const u8, repo: Repo) bool {
    _ = rev;
    _ = repo;
    return false;
}

test {
    std.testing.refAllDecls(@This());
    _ = &Actor;
    _ = &Agent;
    _ = &Blob;
    _ = &Branch;
    _ = &ChangeSet;
    _ = &Commit;
    _ = &Object;
    _ = &Pack;
    _ = &Remote;
    _ = &Repo;
    _ = &SHA;
    _ = &Tag;
    _ = &Tree;
}

test "read" {
    const io = std.testing.io;
    var cwd = std.fs.cwd();
    var file = cwd.openFile(
        "./.git/objects/37/0303630b3fc631a0cb3942860fb6f77446e9c1",
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => {
            return error.SkipZigTest;
            // Sadly this was a predictable error that past me should have know
            // better, alas, actually fixing it [by creating a test vector repo]
            // is still a future me problem!
        },
        else => return err,
    };

    var r_b: [2048]u8 = undefined;
    var reader = file.reader(io, &r_b);
    var z_b: [8 * 1024 * 1024]u8 = undefined;
    var d = zstd.Decompress.init(&reader.interface, &z_b, .{});
    try d.reader.fillMore();
    const b = d.reader.buffered();
    //std.debug.print("{s}\n", .{b[0..count]});
    const commit = try Commit.init(SHA.init("370303630b3fc631a0cb3942860fb6f77446e9c1"), b[11..]);
    //std.debug.print("{}\n", .{commit});
    try std.testing.expectEqualStrings("fcb6817b0efc397f1525ff7ee375e08703ed17a9", commit.tree.hex()[0..]);
    try std.testing.expectEqualStrings("370303630b3fc631a0cb3942860fb6f77446e9c1", commit.sha.hex()[0..]);
}

test "file" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    var cwd = std.fs.cwd();
    var file = cwd.openFile(
        "./.git/objects/37/0303630b3fc631a0cb3942860fb6f77446e9c1",
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => {
            return error.SkipZigTest;
            // Sadly this was a predictable error that past me should have know
            // better, alas, actually fixing it [by creating a test vector repo]
            // is still a future me problem!
        },
        else => return err,
    };
    var r_b: [2048]u8 = undefined;
    var reader = file.reader(io, &r_b);
    var z_b: [8 * 1024 * 1024]u8 = undefined;
    var d = zstd.Decompress.init(&reader.interface, &z_b, .{});
    const dz = try d.reader.readAlloc(a, 0xffff);
    defer a.free(dz);
    const blob = dz[(indexOf(u8, dz, "\x00") orelse unreachable) + 1 ..];
    var commit = try Commit.init(SHA.init("370303630b3fc631a0cb3942860fb6f77446e9c1"), blob);
    //defer commit.raze();
    //std.debug.print("{}\n", .{commit});
    try std.testing.expectEqualStrings("fcb6817b0efc397f1525ff7ee375e08703ed17a9", commit.tree.hex()[0..]);
    try std.testing.expectEqualStrings("370303630b3fc631a0cb3942860fb6f77446e9c1", commit.sha.hex()[0..]);
}

test "not gpg" {
    const null_sha = SHA.init("0000000000000000000000000000000000000000");
    const blob_invalid_0 =
        \\tree 0000bb21f5276fd4f3611a890d12312312415434
        \\parent ffffff8bd96b1abaceaa3298374ab082f4239948
        \\author Some Dude <some@email.com> 1687200000 -0700
        \\committer Some Dude <some@email.com> 1687200000 -0700
        \\gpgsig -----BEGIN SSH SIGNATURE-----
        \\ U1NIU0lHQNTHOUAAADMAAAALc3NoLWVkMjU1MTkAAAAgRa/hEgY+LtKXmU4UizGarF0jm9
        \\ 1DXrxXaR8FmaEJOEUNTHADZ2l0AAAA45839473AINGEUTIAAABTAAAAC3NzaC1lZETN&/3
        \\ BBEAQFzdXKXCV2F5ZXWUo46L5MENOTTEOU98367258dsteuhi876234OEU876+OEU876IO
        \\ 12238aaOEIUvwap+NcCEOEUu9vwQ=
        \\ -----END SSH SIGNATURE-----
        \\
        \\commit message
    ;
    const commit = try Commit.init(null_sha, blob_invalid_0);
    try std.testing.expect(eql(u8, commit.sha.bin[0..], null_sha.bin[0..]));
}

test "toParent" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd.adaptToNewApi(), io);
    defer repo.raze(a, io);
    try repo.loadData(a, io);
    var commit = try repo.headCommit(a, io);

    var count: usize = 0;
    while (true) {
        count += 1;
        if (commit.parent[0]) |_| {
            const parent = try commit.toParent(0, &repo, a, io);
            commit.raze();

            commit = parent;
        } else break;
    }
    commit.raze();
    try std.testing.expect(count >= 31); // LOL SORRY!
}

test "read pack" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.fs.cwd();
    const dir = try cwd.openDir("repos/hastur", .{});
    var repo = try Repo.init(dir.adaptToNewApi(), io);
    defer repo.raze(a, io);

    try repo.loadData(a, io);
    var lol: []u8 = "";

    for (repo.packs, 0..) |pack, pi| {
        for (0..@byteSwap(pack.idx_header.fanout[255])) |oi| {
            const hexy = pack.objnames[oi * 20 .. oi * 20 + 20];
            if (hexy[0] != 0xd2) continue;
            if (false) std.debug.print("{} {} -> {x}\n", .{ pi, oi, hexy });
            if (hexy[1] == 0xb4 and hexy[2] == 0xd1) {
                if (false) std.debug.print("{s} -> {}\n", .{ pack.name, pack.offsets[oi] });
                lol = hexy;
            }
        }
    }
    const obj = try repo.loadObject(SHA.init(lol), a, io);
    defer a.free(obj.commit.memory.?);
    try std.testing.expect(obj == .commit);
    if (false) std.debug.print("{}\n", .{obj});
}

test "pack contains" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.fs.cwd();
    const dir = try cwd.openDir("repos/srctree", .{});
    var repo = try Repo.init(dir.adaptToNewApi(), io);
    try repo.loadData(a, io);
    defer repo.raze(a, io);

    const sha = SHA.init("7d4786ded56e1ee6cfe72c7986218e234961d03c");

    for (repo.packs) |pack| {
        if (try pack.contains(sha)) |_| break;
    } else try std.testing.expect(false); // full sha

    const half_sha: SHA = .initPartial("7d4786ded56e1ee6cfe7");
    for (repo.packs) |pack| {
        if (try pack.contains(half_sha)) |_|
            break;
    } else try std.testing.expect(false); // half sha

    const err = repo.packs[0].contains(SHA.initPartial("7d"));
    try std.testing.expectError(error.AmbiguousRef, err);

    //var long_obj = try repo.findObj(a, lol);
}

test "commit to tree" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd.adaptToNewApi(), io);
    defer repo.raze(a, io);

    try repo.loadData(a, io);

    const cmt = try repo.headCommit(a, io);
    defer cmt.raze();
    const tree = try cmt.loadTree(&repo, a, io);
    defer tree.raze();
    if (false) std.debug.print("tree {}\n", .{tree});
    if (false) for (tree.objects) |obj| std.debug.print("    {}\n", .{obj});
}

test "blob to commit" {
    var a = std.testing.allocator;
    const io = std.testing.io;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd.adaptToNewApi(), io);
    try repo.loadData(a, io);
    defer repo.raze(a, io);

    const cmtt = try repo.headCommit(a, io);
    defer cmtt.raze();

    const tree = try cmtt.loadTree(&repo, a, io);
    defer tree.raze();

    var timer = try std.time.Timer.start();
    var lap = timer.lap();
    const found = try tree.changedSet(&repo, a, io);
    if (false) std.debug.print("found {any}\n", .{found});
    for (found) |f| f.raze(a);
    a.free(found);
    lap = timer.lap();
    if (false) std.debug.print("timer {}\n", .{lap});
}

test "considering optimizing blob to commit" {
    //var a = std.testing.allocator;
    //var cwd = std.fs.cwd();

    //var dir = try cwd.openDir("repos/zig", .{});
    //var repo = try Repo.init(dir);

    ////var repo = try Repo.init(cwd);
    //var timer = try std.time.Timer.start();
    //defer repo.raze(io);

    //try repo.loadPacks(a);

    //const cmtt = try repo.headCommit(a);
    //defer cmtt.raze();

    //const tree = try cmtt.loadTree(a);
    //defer tree.raze(a);
    //var search_list: []?Blob = try a.alloc(?Blob, tree.objects.len);
    //for (tree.objects, search_list) |src, *dst| {
    //    dst.* = src;
    //}
    //defer a.free(search_list);

    //var par = try repo.headCommit(a);
    //var ptree = try par.loadTree(a);

    //var old = par;
    //var oldtree = ptree;
    //var found: usize = 0;
    //var lap = timer.lap();
    //while (found < search_list.len) {
    //    old = par;
    //    oldtree = ptree;
    //    par = try par.toParent(a, 0);
    //    ptree = try par.loadTree(a);
    //    for (search_list) |*search_ish| {
    //        const search = search_ish.* orelse continue;
    //        var line = search.name;
    //        line.len += 21;
    //        line = line[line.len - 20 .. line.len];
    //        if (std.mem.indexOf(u8, ptree.blob, line)) |_| {} else {
    //            search_ish.* = null;
    //            found += 1;
    //            if (false) std.debug.print("    commit for {s} is {s} ({} rem)\n", .{
    //                search.name,
    //                old.sha,
    //                search_list.len - found,
    //            });
    //            continue;
    //        }
    //    }
    //    old.raze();
    //    oldtree.raze(a);
    //}
    //lap = timer.lap();
    //std.debug.print("timer {}\n", .{lap});

    //par.raze(a);
    //ptree.raze(a);
    //par = try repo.headCommit(a);
    //ptree = try par.loadTree(a);

    //var set = std.BufSet.init(a);
    //defer set.deinit();

    //while (set.count() < tree.objects.len) {
    //    old = par;
    //    oldtree = ptree;
    //    par = try par.toParent(a, 0);
    //    ptree = try par.loadTree(a);
    //    if (tree.objects.len != ptree.objects.len) {
    //        objl: for (tree.objects) |obj| {
    //            if (set.contains(&obj.hash)) continue;
    //            for (ptree.objects) |pobj| {
    //                if (std.mem.eql(u8, pobj.name, obj.name)) {
    //                    if (!std.mem.eql(u8, &pobj.hash, &obj.hash)) {
    //                        try set.insert(&obj.hash);
    //                        std.debug.print("    commit for {s} is {s}\n", .{ obj.name, old.sha });
    //                        continue :objl;
    //                    }
    //                }
    //            } else {
    //                try set.insert(&obj.hash);
    //                std.debug.print("    commit added {}\n", .{obj});
    //                continue :objl;
    //            }
    //        }
    //    } else {
    //        for (tree.objects, ptree.objects) |obj, pobj| {
    //            if (set.contains(&obj.hash)) continue;
    //            if (!std.mem.eql(u8, &pobj.hash, &obj.hash)) {
    //                if (std.mem.eql(u8, pobj.name, obj.name)) {
    //                    try set.insert(&obj.hash);
    //                    std.debug.print("    commit for {s} is {s}\n", .{ obj.name, old.sha });
    //                    continue;
    //                } else std.debug.print("    error on commit for {}\n", .{obj});
    //            }
    //        }
    //    }
    //    old.raze();
    //    oldtree.raze(a);
    //}
    //lap = timer.lap();
    //std.debug.print("timer {}\n", .{lap});

    //par.raze(a);
    //ptree.raze(a);
}

test "ref delta" {
    var a = std.testing.allocator;
    const io = std.testing.io;
    var cwd = std.fs.cwd();
    const dir = cwd.openDir("repos/hastur", .{}) catch return error.skip;

    var repo = try Repo.init(dir.adaptToNewApi(), io);
    defer repo.raze(a, io);

    try repo.loadData(a, io);

    const cmtt = try repo.headCommit(a, io);
    defer cmtt.raze();

    const tree = try cmtt.loadTree(&repo, a, io);
    defer tree.raze();

    var timer = try std.time.Timer.start();
    var lap = timer.lap();
    const found = try tree.changedSet(&repo, a, io);
    if (false) std.debug.print("found {any}\n", .{found});
    for (found) |f| f.raze(a);
    a.free(found);
    lap = timer.lap();
    if (false) std.debug.print("timer {}\n", .{lap});
}

test "forkRemote" {
    const a = std.testing.allocator;
    var tdir = std.testing.tmpDir(.{});
    defer tdir.cleanup();

    const agent = Agent{
        .alloc = a,
        .cwd = tdir.dir,
    };
    _ = agent;
    // TODO don't get banned from github
    //var result = try act.forkRemote("https://github.com/grayhatter/srctree", "srctree_tmp");
    //std.debug.print("{s}\n", .{result});
}

test "new repo" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tdir = std.testing.tmpDir(.{});
    defer tdir.cleanup();

    var new_repo = try Repo.createNew(tdir.dir, "new_repo", a, io);
    _ = try tdir.dir.openDir("new_repo", .{});
    try new_repo.loadData(a, io);
    defer new_repo.raze(a, io);
}

test "updated at" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd.adaptToNewApi(), io);
    defer repo.raze(a, io);

    try repo.loadData(a, io);
    const oldest = try repo.updatedAt(a, io);
    _ = oldest;
    //std.debug.print("{}\n", .{oldest});
}

test "list remotes" {
    const a = std.testing.allocator;
    const io = std.testing.io;

    const cwd = try std.fs.cwd().openDir(".", .{});
    var repo = try Repo.init(cwd.adaptToNewApi(), io);
    try repo.loadData(a, io);
    defer repo.raze(a, io);
    const remotes = repo.remotes orelse unreachable;
    try std.testing.expect(remotes.len >= 2);
    try std.testing.expectEqualStrings("github", remotes[0].name);
    try std.testing.expectEqualStrings("gr.ht", remotes[1].name);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const zstd = std.compress.zstd;
