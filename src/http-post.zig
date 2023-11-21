const std = @import("std");

const Allocator = std.mem.Allocator;

/// This is the preferred api to use... once it actually exists :D
pub const Validator = struct {
    post_data: PostData,

    pub fn init(pd: PostData) Validator {
        return Validator{
            .post_data = pd,
        };
    }

    pub fn require(v: *Validator, name: []const u8) !PostItem {
        return v.optional(name) orelse error.NotFound;
    }

    pub fn optional(v: *Validator, name: []const u8) ?PostItem {
        for (v.post_data.items) |item| {
            if (std.mem.eql(u8, item.name, name)) return item;
        }
        return null;
    }

    pub fn files(_: *Validator, _: []const u8) !void {
        return error.NotImplemented;
    }
};

pub const DataKind = enum {
    @"form-data",
};

pub const PostItem = struct {
    data: []const u8,
    headers: ?[]const u8 = null,
    body: ?[]const u8 = null,

    kind: DataKind = .@"form-data",
    name: []const u8,
    value: []const u8,
};

pub const PostData = struct {
    rawdata: []u8,
    items: []PostItem,

    pub fn validator(self: PostData) Validator {
        return Validator.init(self);
    }
};

pub const ContentType = union(enum) {
    const Application = enum {
        @"x-www-form-urlencoded",
        @"x-git-upload-pack-request",
    };
    const MultiPart = enum {
        mixed,
        @"form-data",
    };
    multipart: MultiPart,
    application: Application,

    fn subWrap(comptime Kind: type, str: []const u8) !Kind {
        inline for (std.meta.fields(Kind)) |field| {
            if (std.mem.startsWith(u8, str, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return error.UnknownContentType;
    }

    fn wrap(comptime kind: type, val: anytype) !ContentType {
        return switch (kind) {
            MultiPart => .{ .multipart = try subWrap(kind, val) },
            Application => .{ .application = try subWrap(kind, val) },
            else => @compileError("not implemented type"),
        };
    }

    pub fn fromStr(str: []const u8) !ContentType {
        inline for (std.meta.fields(ContentType)) |field| {
            if (std.mem.startsWith(u8, str, field.name)) {
                return wrap(field.type, str[field.name.len + 1 ..]);
            }
        }
        return error.UnknownContentType;
    }
};

fn normilizeUrlEncoded(string: []u8) ![]u8 {
    for (string) |*c| {
        if (c.* == '+') c.* = ' ';
    }
    return string;
}

fn parseApplication(a: Allocator, ap: ContentType.Application, data: []u8, htype: []const u8) ![]PostItem {
    switch (ap) {
        .@"x-www-form-urlencoded" => {
            std.debug.assert(std.mem.startsWith(u8, htype, "application/x-www-form-urlencoded"));

            var itr = std.mem.split(u8, data, "&");
            const count = std.mem.count(u8, data, "&") +| 1;
            var items = try a.alloc(PostItem, count);
            for (items) |*itm| {
                var idata: []u8 = @constCast(itr.next().?);
                var name = idata;
                var value = idata;
                if (std.mem.indexOf(u8, idata, "=")) |i| {
                    name = try normilizeUrlEncoded(idata[0..i]);
                    value = try normilizeUrlEncoded(idata[i + 1 ..]);
                }
                itm.* = .{
                    .data = idata,
                    .name = name,
                    .value = value,
                };
            }
            return items;
        },
        .@"x-git-upload-pack-request" => {
            // Git just uses the raw data instead, no need to preprocess
            return &[0]PostItem{};
        },
    }
}

const DataHeader = enum {
    @"Content-Disposition",
    @"Content-Type",

    pub fn fromStr(str: []const u8) !DataHeader {
        inline for (std.meta.fields(DataHeader)) |field| {
            if (std.mem.startsWith(u8, str, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        std.log.info("'{s}'", .{str});
        return error.UnknownHeader;
    }
};

const MultiData = struct {
    header: DataHeader,
    str: []const u8,
    name: ?[]const u8 = null,
    filename: ?[]const u8 = null,

    fn update(md: *MultiData, str: []const u8) void {
        var trimmed = std.mem.trim(u8, str, " \t\n\r");
        if (std.mem.indexOf(u8, trimmed, "=")) |i| {
            if (std.mem.eql(u8, trimmed[0..i], "name")) {
                md.name = trimmed[i + 1 ..];
            } else if (std.mem.eql(u8, trimmed[0..i], "filename")) {
                md.filename = trimmed[i + 1 ..];
            }
        }
    }
};

fn parseMultiData(data: []const u8) !MultiData {
    var extra = std.mem.split(u8, data, ";");
    const first = extra.first();
    var header = try DataHeader.fromStr(first);
    var mdata: MultiData = .{
        .header = header,
        .str = first[@tagName(header).len + 1 ..],
    };

    while (extra.next()) |each| {
        mdata.update(each);
    }

    return mdata;
}

fn parseMultiFormData(a: Allocator, data: []const u8) !PostItem {
    _ = a;
    std.debug.assert(std.mem.startsWith(u8, data, "\r\n"));
    if (std.mem.indexOf(u8, data, "\r\n\r\n")) |i| {
        var post_item = PostItem{
            .data = data,
            .name = undefined,
            .value = data[i + 4 ..],
        };

        post_item.headers = data[0..i];
        var headeritr = std.mem.split(u8, post_item.headers.?, "\r\n");
        while (headeritr.next()) |header| {
            if (header.len == 0) continue;
            var md = try parseMultiData(header);
            if (md.name) |name| post_item.name = name;
            // TODO look for other headers or other data
        }
        return post_item;
    }
    return error.UnableToParseFormData;
}

/// Pretends to follow RFC2046
fn parseMulti(a: Allocator, mp: ContentType.MultiPart, data: []const u8, htype: []const u8) ![]PostItem {
    var boundry_buffer = [_]u8{'-'} ** 74;
    switch (mp) {
        .mixed => {
            return error.NotImplemented;
        },
        .@"form-data" => {
            std.debug.assert(std.mem.startsWith(u8, htype, "multipart/form-data; boundary="));
            std.debug.assert(htype.len > 30);
            const bound_given = htype[30..];
            @memcpy(boundry_buffer[2 .. bound_given.len + 2], bound_given);

            const boundry = boundry_buffer[0 .. bound_given.len + 2];
            const count = std.mem.count(u8, data, boundry) -| 1;
            var items = try a.alloc(PostItem, count);
            var itr = std.mem.split(u8, data, boundry);
            _ = itr.first(); // the RFC says I'm supposed to ignore the preamble :<
            for (items) |*itm| {
                itm.* = try parseMultiFormData(a, itr.next().?);
            }
            std.debug.assert(std.mem.eql(u8, itr.rest(), "--\r\n"));
            return items;
        },
    }
}

pub fn readBody(a: Allocator, acpt: std.net.StreamServer.Connection, size: usize, htype: []const u8) !PostData {
    var post_buf: []u8 = try a.alloc(u8, size);
    var read_size = try acpt.stream.read(post_buf);
    if (read_size != size) return error.UnexpectedHttpBodySize;

    const items = switch (try ContentType.fromStr(htype)) {
        .application => |ap| try parseApplication(a, ap, post_buf, htype),
        .multipart => |mp| try parseMulti(a, mp, post_buf, htype),
    };

    return .{
        .rawdata = post_buf,
        .items = items,
    };
}

test "multipart/mixed" {}

test "multipart/form-data" {}

test "multipart/multipart" {}

test "application/x-www-form-urlencoded" {}
