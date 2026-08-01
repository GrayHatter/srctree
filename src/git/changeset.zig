sha: Sha,
name: []const u8,
title: []const u8,
timestamp: i64,

const ChangeSet = @This();

pub fn init(a: Allocator, name: []const u8, commit: *const Commit) !ChangeSet {
    return .{
        .sha = commit.sha,
        .name = try a.dupe(u8, name),
        .title = try a.dupe(u8, trim(u8, commit.title, " \n")),
        .timestamp = commit.committer.timestamp,
    };
}

pub fn fromCommit(self: *const Tree, repo: *const Repo, root_commit: *const Commit, a: Allocator, io: Io) ![]ChangeSet {
    const search_list: []?Blob = try a.alloc(?Blob, self.count());
    defer a.free(search_list);
    var changed = try a.alloc(ChangeSet, self.count());
    errdefer a.free(changed);
    errdefer for (changed) |ch| ch.raze(a);

    var itr = self.iterate();
    for (search_list, changed) |*srch, *chng| {
        srch.* = itr.next() orelse unreachable;
        chng.* = .{ .sha = .empty, .name = &.{}, .title = &.{}, .timestamp = 0 };
    }

    var parent: Commit = root_commit.*;
    parent.bytes = try a.dupe(u8, parent.bytes);
    defer parent.raze(a);
    var tree = try root_commit.loadTree(repo, a, io);
    defer tree.raze(a);

    var found: usize = 0;
    while (found < search_list.len) {
        if (parent.toParent(0, repo, a, io)) |p| {
            parent.raze(a);
            parent = p;
        } else |err| switch (err) {
            error.NoParent, error.ObjectInvalid => {
                for (search_list, 0..) |search_ish, i| {
                    if (search_ish) |search| {
                        found += 1;
                        changed[i] = try .init(a, search.name, &parent);
                    }
                }
                break;
            },
            else => |e| return e,
        }

        if (parent.loadTree(repo, a, io)) |t| {
            tree.raze(a);
            tree = t;
        } else |err| switch (err) {
            error.ObjectInvalid => {
                for (search_list, 0..) |search_ish, i| {
                    if (search_ish) |search| {
                        found += 1;
                        changed[i] = try .init(a, search.name, &parent);
                    }
                }
                break;
            },
            else => |e| return e,
        }
        for (search_list, 0..) |*search_ish, i| {
            const search = search_ish.* orelse continue;
            const sha_bin: []const u8 = switch (search.sha.hash) {
                .sha1 => |sh| &sh,
                .sha256 => |sh| &sh,
                .partial => unreachable,
            };
            if (find(u8, tree.bytes, sha_bin) == null) {
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
