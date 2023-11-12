const std = @import("std");

const Allocator = std.mem.Allocator;

pub const PostItem = struct {
    data: []const u8,
    headers: []const u8,
    body: []const u8,
    //kind: []u8,
};

pub const PostData = struct {
    rawdata: []u8,
    items: []PostItem,
};

pub const ContentType = union(enum) {
    const Application = enum {
        @"x-www-form-urlencoded",
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

fn parseApplication(a: Allocator, ap: ContentType.Application, data: []const u8, htype: []const u8) ![]PostItem {
    switch (ap) {
        .@"x-www-form-urlencoded" => {
            std.debug.assert(std.mem.startsWith(u8, htype, "application/x-www-form-urlencoded"));

            var itr = std.mem.split(u8, data, "&");
            const count = std.mem.count(u8, data, "&") +| 1;
            var items = try a.alloc(PostItem, count);
            for (items) |*itm| {
                const idata = itr.next().?;
                var headers = idata;
                var body = idata;
                if (std.mem.indexOf(u8, idata, "=")) |i| {
                    headers = idata[0..i];
                    body = idata[i + 1 ..];
                }
                itm.* = .{
                    .data = idata,
                    .headers = headers,
                    .body = body,
                };
            }
            return items;
        },
    }
}

fn parseMulti(a: Allocator, mp: ContentType.MultiPart, data: []const u8, htype: []const u8) ![]PostItem {
    switch (mp) {
        .mixed => {
            return error.NotImplemented;
        },
        .@"form-data" => {
            std.debug.assert(std.mem.startsWith(u8, htype, "multipart/form-data; boundary="));

            const boundry = htype[30..];
            const count = std.mem.count(u8, data, boundry) -| 1;
            var items = try a.alloc(PostItem, count);
            var itr = std.mem.split(u8, data, boundry);
            _ = itr.first(); // the RFC says I'm supposed to ignore the preamble :<
            for (items) |*itm| {
                const idata = itr.next().?;
                std.debug.assert(std.mem.startsWith(u8, idata, "\r\n"));
                var headers = idata;
                var body = idata;
                if (std.mem.indexOf(u8, idata, "\r\n\r\n")) |i| {
                    headers = idata[0..i];
                    body = idata[i + 4 ..];
                }
                itm.* = .{
                    .data = idata,
                    .headers = headers,
                    .body = body,
                };
            }
            std.debug.assert(std.mem.eql(u8, itr.rest(), "--\r\n"));
            return items;
        },
    }
}

pub fn readBody(a: Allocator, acpt: std.net.StreamServer.Connection, size: usize, htype: []const u8) !PostData {
    var post_buf: []u8 = try a.alloc(u8, size);
    _ = try acpt.stream.read(post_buf);

    const items = switch (try ContentType.fromStr(htype)) {
        .application => |ap| try parseApplication(a, ap, post_buf, htype),
        .multipart => |mp| try parseMulti(a, mp, post_buf, htype),
    };

    return .{
        .rawdata = post_buf,
        .items = items,
    };
}
