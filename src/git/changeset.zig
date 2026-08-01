sha: Sha,
name: []const u8,
title: []const u8,
timestamp: i64,

const ChangeSet = @This();

pub const Error = error{
    OutOfMemory,
    Canceled,
    Io,
    ObjectCorrupt,
    ObjectMissing,
    ObjectInvalid,
    NotATree,
};

pub fn init(a: Allocator, name: []const u8, commit: *const Commit) error{OutOfMemory}!ChangeSet {
    return .{
        .sha = commit.sha,
        .name = try a.dupe(u8, name),
        .title = try a.dupe(u8, trim(u8, commit.title, " \n")),
        .timestamp = commit.committer.timestamp,
    };
}

pub fn fromCommit(starting_tree: *const Tree, repo: *const Repo, root_commit: *const Commit, a: Allocator, io: Io) Error![]ChangeSet {
    const count = starting_tree.count();
    const search_list: []?Blob = try a.alloc(?Blob, count);
    defer a.free(search_list);
    var changed = try a.alloc(ChangeSet, count);
    errdefer a.free(changed);
    errdefer for (changed) |ch| ch.raze(a);

    var itr = starting_tree.iterate();
    for (search_list, changed) |*srch, *chng| {
        srch.* = itr.next() orelse unreachable;
        chng.* = .{ .sha = .empty, .name = &.{}, .title = &.{}, .timestamp = 0 };
    }

    var parent: Commit = root_commit.*;
    parent.bytes = try a.dupe(u8, parent.bytes);
    defer parent.raze(a);
    var tree = root_commit.loadTreeDescend(starting_tree.basepath, repo, a, io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        error.ObjectCorrupt => return error.ObjectCorrupt,
        error.ObjectInvalid => return error.ObjectInvalid,
        error.ShaNotFound, error.FileNotFound, error.ObjectMissing => return error.ObjectMissing,
        error.NotATree => return error.NotATree,
        error.CurrentTree => starting_tree.*,
        error.InvalidTreeSha,
        error.PathNotFound,
        error.InvalidPath,
        => // Assume the file/directory was added in the previous commit
        unreachable,
        error.SystemResources,
        error.AccessDenied,
        error.PermissionDenied,
        error.NoDevice,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.SymLinkLoop,
        error.NetworkNotFound,
        error.NameTooLong,
        error.BadPathName,
        error.NotDir,
        error.OtherFileSys,
        => return error.Io,
        error.Unexpected => unreachable, // TODO fix, stdlib says it's impossible but.....
        error.Ambiguous => unreachable, // TODO
    };
    defer tree.raze(a);

    var found: usize = 0;
    while (found < search_list.len) {
        if (parent.toParent(0, repo, a, io)) |p| {
            parent.raze(a);
            parent = p;
        } else |err| switch (err) {
            error.NoParent,
            error.ObjectInvalid,
            => { // Finish, and bail out if we can't find the parent
                for (search_list, 0..) |search_ish, i|
                    if (search_ish) |search| {
                        found += 1;
                        changed[i] = try .init(a, search.name, &parent);
                    };
                break;
            },
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            error.NotACommit, error.ObjectCorrupt => return error.ObjectCorrupt,
            error.FileNotFound, error.ShaNotFound, error.ObjectMissing => return error.ObjectMissing,
            error.SystemResources,
            error.AccessDenied,
            error.PermissionDenied,
            error.NoDevice,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SymLinkLoop,
            error.NetworkNotFound,
            error.NameTooLong,
            error.BadPathName,
            error.OtherFileSys,
            error.NotDir,
            => return error.Io,
            error.Unexpected => unreachable,
            error.Ambiguous => unreachable, // TODO
        }

        if (parent.loadTreeDescend(tree.basepath, repo, a, io)) |t| {
            tree.raze(a);
            tree = t;
        } else |err| switch (err) {
            error.CurrentTree => {},
            error.InvalidTreeSha,
            error.PathNotFound,
            error.InvalidPath, // Assume the file/directory was added in the previous commit
            error.ObjectInvalid,
            => {
                for (search_list, 0..) |search_ish, i| {
                    if (search_ish) |search| {
                        found += 1;
                        changed[i] = try .init(a, search.name, &parent);
                    }
                }
                break;
            },

            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            error.ObjectCorrupt => return error.ObjectCorrupt,
            error.ObjectMissing => return error.ObjectMissing,
            error.SystemResources,
            error.AccessDenied,
            error.PermissionDenied,
            error.NoDevice,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SymLinkLoop,
            error.NetworkNotFound,
            error.NameTooLong,
            error.BadPathName,
            => return error.Io,
            error.Unexpected => unreachable,
            error.FileNotFound => unreachable,
            error.NotDir => unreachable,
            error.Ambiguous => unreachable,
            error.ShaNotFound => unreachable,
            error.OtherFileSys => unreachable,
            error.NotATree => unreachable,
        }

        for (search_list, 0..) |*search_ish, i| {
            const search = search_ish.* orelse continue;
            // This naive find can introduce a bug when targets are renamed
            if (find(u8, tree.bytes, search.sha.hash.bytes()) == null) {
                search_ish.* = null;
                found += 1;
                changed[i] = try .init(a, search.name, &parent);
                continue;
            }
        }
    }

    return changed;
}

pub fn raze(cs: ChangeSet, a: Allocator) void {
    a.free(cs.name);
    a.free(cs.title);
}

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const find = std.mem.find;
const Commit = @import("Commit.zig");
const Sha = @import("Sha.zig");
const Tree = @import("Tree.zig");
const Blob = @import("blob.zig");
const Repo = @import("Repo.zig");
const trim = std.mem.trim;
