const std = @import("std");
const Type = @import("builtin").Type;

const Allocator = std.mem.Allocator;

/// This is the preferred api to use... once it actually exists :D
pub fn Validator(comptime T: type) type {
    return struct {
        data: T,

        const Self = @This();

        pub fn init(data: T) Self {
            return Self{
                .data = data,
            };
        }

        pub fn count(v: *Self, name: []const u8) usize {
            var i: usize = 0;
            for (v.data.items) |item| {
                if (std.mem.eql(u8, item.name, name)) i += 1;
            }
            return i;
        }

        pub fn require(v: *Self, name: []const u8) !DataItem {
            return v.optional(name) orelse error.DataMissing;
        }

        pub fn requirePos(v: *Self, name: []const u8, skip: usize) !DataItem {
            var skipped: usize = skip;
            for (v.data.items) |item| {
                if (std.mem.eql(u8, item.name, name)) {
                    if (skipped > 0) {
                        skipped -= 1;
                        continue;
                    }
                    return item;
                }
            }
            return error.DataMissing;
        }

        pub fn optional(v: *Self, name: []const u8) ?DataItem {
            for (v.data.items) |item| {
                if (std.mem.eql(u8, item.name, name)) return item;
            }
            return null;
        }

        pub fn files(_: *Self, _: []const u8) !void {
            return error.NotImplemented;
        }
    };
}

pub fn validator(data: anytype) Validator(@TypeOf(data)) {
    return Validator(@TypeOf(data)).init(data);
}

pub const DataKind = enum {
    @"form-data",
};

pub const DataItem = struct {
    data: []const u8,
    headers: ?[]const u8 = null,
    body: ?[]const u8 = null,

    kind: DataKind = .@"form-data",
    name: []const u8,
    value: []const u8,
};

pub const PostData = struct {
    rawpost: []u8,
    items: []DataItem,

    pub fn validator(self: PostData) Validator(PostData) {
        return Validator(PostData).init(self);
    }
};

pub const QueryData = struct {
    alloc: Allocator,
    rawquery: []const u8,
    items: []DataItem,

    /// segments name=value&name2=otherval
    /// segment in  name=%22dquote%22
    /// segment out name="dquote"
    fn parseSegment(a: Allocator, seg: []const u8) !DataItem {
        if (std.mem.indexOf(u8, seg, "=")) |i| {
            const alen = seg.len - i - 1;
            const input = seg[i + 1 .. seg.len];
            var value: []u8 = @constCast(input);
            if (alen > 0) {
                value = try a.alloc(u8, alen);
                value = try normalizeUrlEncoded(input, value);
            }
            return .{
                .data = seg,
                .name = seg[0..i],
                .value = value,
            };
        } else {
            return .{
                .data = seg,
                .name = seg,
                .value = seg[seg.len..seg.len],
            };
        }
    }

    /// TODO leaks on error
    pub fn init(a: Allocator, query: []const u8) !QueryData {
        var itr = std.mem.split(u8, query, "&");
        const count = std.mem.count(u8, query, "&") + 1;
        const items = try a.alloc(DataItem, count);
        for (items) |*item| {
            item.* = try parseSegment(a, itr.next().?);
        }

        return QueryData{
            .alloc = a,
            .rawquery = query,
            .items = items,
        };
    }

    pub fn validator(self: QueryData) Validator(QueryData) {
        return Validator(QueryData).init(self);
    }
};

pub const RequestData = struct {
    post_data: ?PostData,
    query_data: QueryData,
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

pub fn UserData(comptime T: type) type {
    return struct {
        req: T,

        const Self = @This();

        pub fn init(data: anytype) !T {
            return switch (@TypeOf(data)) {
                QueryData => initQuery(data),
                PostData => initPost(data),
                else => comptime unreachable,
            };
        }

        pub fn initMap(a: Allocator, data: anytype) !T {
            return switch (@TypeOf(data)) {
                QueryData => comptime unreachable, // Not implemented
                PostData => initPostMap(a, data),
                else => comptime unreachable,
            };
        }

        fn initQuery(data: QueryData) !T {
            var valid = data.validator();

            var req: T = undefined;
            inline for (std.meta.fields(T)) |field| {
                @field(req, field.name) = switch (@typeInfo(field.type)) {
                    .Optional => if (valid.optional(field.name)) |o| o.value else null,
                    .Pointer => (try valid.require(field.name)).value,
                    else => unreachable,
                };
            }
            return req;
        }

        fn initPost(data: PostData) !T {
            var valid = data.validator();

            var req: T = undefined;
            inline for (std.meta.fields(T)) |field| {
                @field(req, field.name) = switch (@typeInfo(field.type)) {
                    .Optional => if (valid.optional(field.name)) |o| o.value else null,
                    .Pointer => (try valid.require(field.name)).value,
                    else => unreachable,
                };
            }
            return req;
        }

        fn initPostMap(a: Allocator, data: PostData) !T {
            var valid = data.validator();

            var req: T = undefined;
            inline for (std.meta.fields(T)) |field| {
                @field(req, field.name) = switch (@typeInfo(field.type)) {
                    .Optional => if (valid.optional(field.name)) |o| o.value else null,
                    .Pointer => |fptr| switch (fptr.child) {
                        u8 => (try valid.require(field.name)).value,
                        []const u8 => arr: {
                            const count = valid.count(field.name);
                            var map = try a.alloc([]const u8, count);
                            for (0..count) |i| {
                                map[i] = (try valid.requirePos(field.name, i)).value;
                            }
                            break :arr map;
                        },
                        else => comptime unreachable,
                    },
                    else => unreachable,
                };
            }
            return req;
        }
    };
}

fn normalizeUrlEncoded(in: []const u8, out: []u8) ![]u8 {
    var len: usize = 0;
    var i: usize = 0;
    while (i < in.len) {
        const c = &in[i];
        var char: u8 = 0xff;
        switch (c.*) {
            '+' => char = ' ',
            '%' => {
                if (i + 2 >= in.len) {
                    char = c.*;
                    continue;
                }
                char = std.fmt.parseInt(u8, in[i + 1 ..][0..2], 16) catch '%';
                i += 2;
            },
            else => |o| char = o,
        }
        out[len] = char;
        len += 1;
        i += 1;
    }
    return out[0..len];
}

fn parseApplication(a: Allocator, ap: ContentType.Application, data: []u8, htype: []const u8) ![]DataItem {
    switch (ap) {
        .@"x-www-form-urlencoded" => {
            std.debug.assert(std.mem.startsWith(u8, htype, "application/x-www-form-urlencoded"));

            var itr = std.mem.split(u8, data, "&");
            const count = std.mem.count(u8, data, "&") +| 1;
            const items = try a.alloc(DataItem, count);
            for (items) |*itm| {
                const idata = itr.next().?;
                var odata = try a.dupe(u8, idata);
                var name = odata;
                var value = odata;
                if (std.mem.indexOf(u8, idata, "=")) |i| {
                    name = try normalizeUrlEncoded(idata[0..i], odata[0..i]);
                    value = try normalizeUrlEncoded(idata[i + 1 ..], odata[i + 1 ..]);
                }
                itm.* = .{
                    .data = odata,
                    .name = name,
                    .value = value,
                };
            }
            return items;
        },
        .@"x-git-upload-pack-request" => {
            // Git just uses the raw data instead, no need to preprocess
            return &[0]DataItem{};
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
    const header = try DataHeader.fromStr(first);
    var mdata: MultiData = .{
        .header = header,
        .str = first[@tagName(header).len + 1 ..],
    };

    while (extra.next()) |each| {
        mdata.update(each);
    }

    return mdata;
}

fn parseMultiFormData(a: Allocator, data: []const u8) !DataItem {
    _ = a;
    std.debug.assert(std.mem.startsWith(u8, data, "\r\n"));
    if (std.mem.indexOf(u8, data, "\r\n\r\n")) |i| {
        var post_item = DataItem{
            .data = data,
            .name = undefined,
            .value = data[i + 4 ..],
        };

        post_item.headers = data[0..i];
        var headeritr = std.mem.split(u8, post_item.headers.?, "\r\n");
        while (headeritr.next()) |header| {
            if (header.len == 0) continue;
            const md = try parseMultiData(header);
            if (md.name) |name| post_item.name = name;
            // TODO look for other headers or other data
        }
        return post_item;
    }
    return error.UnableToParseFormData;
}

/// Pretends to follow RFC2046
fn parseMulti(a: Allocator, mp: ContentType.MultiPart, data: []const u8, htype: []const u8) ![]DataItem {
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
            const items = try a.alloc(DataItem, count);
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

pub fn readBody(
    a: Allocator,
    acpt: std.net.Server.Connection,
    size: usize,
    htype: []const u8,
) !PostData {
    const post_buf: []u8 = try a.alloc(u8, size);
    const read_size = try acpt.stream.read(post_buf);
    if (read_size != size) return error.UnexpectedHttpBodySize;

    const items = switch (try ContentType.fromStr(htype)) {
        .application => |ap| try parseApplication(a, ap, post_buf, htype),
        .multipart => |mp| try parseMulti(a, mp, post_buf, htype),
    };

    return .{
        .rawpost = post_buf,
        .items = items,
    };
}

pub fn readQuery(a: Allocator, query: []const u8) !QueryData {
    return QueryData.init(a, query);
}

pub fn parseRequestData(
    a: Allocator,
    query: []const u8,
    acpt: std.net.StreamServer.Connection,
    size: usize,
    htype: []const u8,
) !RequestData {
    return RequestData{
        .post_data = try readBody(a, acpt, size, htype),
        .query_data = try readQuery(a, query),
    };
}

test "multipart/mixed" {}

test "multipart/form-data" {}

test "multipart/multipart" {}

test "application/x-www-form-urlencoded" {}
