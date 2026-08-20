const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Journaling = @This();

pub const Header = struct {
    inet: [16]u8 = u8{0} ** 16,
};

pub const EvtComment = struct {
    header: Header,
};

pub const EvtRepoCreate = struct {
    header: Header,
};

pub const EventKind = enum(u8) {
    comment = 0x00,
    create_repo = 0x01,
};

pub const Events = union(EventKind) {
    comment: EvtComment,
    create_repo: EvtRepoCreate,
};

pub const Journal = struct {
    username: []u8,
    mtls_fp: ?[]u8 = null,

    pub fn readFile(a: Allocator, username: []const u8, file: std.fs.File) !Journal {
        defer file.close();

        var fp: ?[]u8 = try a.alloc(u8, 40);
        errdefer if (fp) |ffp| a.free(ffp);
        var count = try file.read(fp.?);
        if (count != 40) {
            a.free(fp.?);
            fp = null;
        }
        return Journal{
            .username = try a.dupe(u8, username),
            .mtls_fp = fp,
        };
    }
};

var datad: std.fs.Dir = undefined;

pub fn init(dir: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "{s}/users", .{dir});
    datad = try std.fs.cwd().openDir(filename, .{});
}

pub fn raze() void {
    datad.close();
}

pub fn new() !Journal {
    return error.NotImplemnted;
}

pub fn open(a: Allocator, username: []const u8) !Journal {
    for (username) |c| if (!std.ascii.isLower(c)) return error.InvalidUsername;

    const ufile = datad.openFile(username, .{}) catch return error.UserNotFound;
    return try Journal.readFile(a, ufile);
}
