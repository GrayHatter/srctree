pub const verse_name = .auth;

//pub const verse_router = &router;

const routes = [_]Router.Match{
    GET("auth", view),
    GET("finger", view),
};

pub const index = view;

const AuthPage = T.PageData("auth.html");

pub fn router(f: *Frame) Router.RoutingError!Router.BuildFn {
    if (!std.mem.eql(u8, f.uri.next() orelse "", "auth")) return error.Unrouteable;

    if (f.uri.peek()) |peek| {
        if (peek.len == 64) {
            for (peek) |chr| {
                switch (chr) {
                    'a'...'f', '0'...'9' => continue,
                    else => return error.Unrouteable,
                }
            } else return view;
        } else return error.NotFound;
    } else return Router.defaultRouter(f, &routes);
}

fn view(f: *Frame) Error!void {
    // TODO move this back into context somehow

    var page = AuthPage.init(.{
        .meta_head = .{ .open_graph = .{} },
        .body_header = common.bodyHeader(f),
    });

    return f.sendPage(&page);
}

test {
    _ = &std.testing.refAllDecls(@This());
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const allocPrint = std.fmt.allocPrint;
const Writer = std.Io.Writer;

const verse = @import("verse");
const Abx = verse.Antibiotic;
const Frame = verse.Frame;
const T = verse.template;
const S = T.Structs;
const Router = verse.Router;
const Error = Router.Error;
const POST = Router.POST;
const GET = Router.GET;

const common = @import("common.zig");
