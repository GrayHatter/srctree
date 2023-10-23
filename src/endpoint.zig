const std = @import("std");

pub const HTML = @import("html.zig");
pub const Response = @import("response.zig");
pub const Template = @import("template.zig");

pub const Error = error{
    Unknown,
    ReqResInvalid,
    AndExit,
    OutOfMemory,
    Unrouteable,
};

pub const Endpoint = *const fn (*Response, []const u8) Error!void;

pub const commitFlex = @import("endpoints/commit-flex.zig").commitFlex;
pub const repoList = @import("endpoints/repo-list.zig").list;
pub const repoTree = @import("endpoints/repo-list.zig").tree;
pub const code = @import("endpoints/source-view.zig").code;

pub fn repo(uri: []const u8) Error!Endpoint {
    std.debug.print("ep route {s}\n", .{uri});
    for (uri) |c| if (!std.ascii.isLower(c)) return error.Unrouteable;

    var cwd = std.fs.cwd();
    if (cwd.openIterableDir("./repos", .{})) |idir| {
        var itr = idir.iterate();

        while (itr.next() catch return error.Unrouteable) |file| {
            if (file.kind != .directory and file.kind != .sym_link) continue;
            if (std.mem.eql(u8, file.name, uri)) return &repoTree;
        }
    } else |_| {}
    return error.Unrouteable;
}
