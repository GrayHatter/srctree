const std = @import("std");
const Context = @import("../context.zig");
const Template = @import("../template.zig");
const UserData = @import("../request_data.zig").UserData;

const Gist = @import("../types.zig").Gist;

const Route = @import("../routes.zig");
const Error = Route.Error;
const POST = Route.POST;
const GET = Route.GET;

const GistPage = Template.PageData("gist.html");
const GistNewPage = Template.PageData("gist_new.html");

const endpoints = [_]Route.Match{
    GET("", view),
    GET("gist", view),
    GET("new", new),
    POST("new", post),
    POST("post", post),
};

pub fn router(ctx: *Context) Error!Route.Callable {
    if (!std.mem.eql(u8, ctx.uri.next() orelse "", "gist")) return error.Unrouteable;

    if (ctx.uri.peek()) |peek| {
        if (peek.len == 64) {
            for (peek) |chr| {
                switch (chr) {
                    'a'...'f', '0'...'9' => continue,
                    else => return error.Unrouteable,
                }
            } else {
                return view;
            }
        }
    }

    return Route.router(ctx, &endpoints);
}

const GistPost = struct {
    file_name: [][]const u8,
    file_blob: [][]const u8,
};

fn post(ctx: *Context) Error!void {
    try ctx.request.auth.validOrError();

    const postd = ctx.req_data.post_data orelse return error.BadData;
    const udata = UserData(GistPost).initMap(ctx.alloc, postd) catch return error.BadData;
    // I assume this is still enforced in ReleaseFast but I want to control the
    // error returned
    if (udata.file_name.len != udata.file_blob.len) return error.BadData;

    const username = if (ctx.auth.valid())
        (ctx.auth.user(ctx.alloc) catch unreachable).username
    else
        "public";

    const hash_str: [64]u8 = Gist.new(username, udata.file_name, udata.file_blob) catch return error.Unknown;

    return ctx.response.redirect("/gist/" ++ hash_str, true) catch unreachable;
}

fn new(ctx: *Context) Error!void {
    const tmpl = Template.findTemplate("gist_new.html");
    // TODO move this back into context somehow
    var btns = [1]Template.Structs.Navbuttons{
        .{
            .name = "inbox",
            .url = "/inbox",
        },
    };

    var files = [1]Template.Structs.Gistfiles{.{}};

    var page = GistNewPage.init(tmpl, .{
        .meta_head = .{
            .open_graph = .{
                .title = "Create A New Gist",
            },
        },
        .body_header = .{
            .nav = .{
                .nav_auth = undefined,
                .nav_buttons = &btns,
            },
        },
        .gist_files = &files,
    });

    return ctx.sendPage(&page);
}

fn view(ctx: *Context) Error!void {
    const tmpl = Template.findTemplate("gist.html");

    // TODO move this back into context somehow
    var btns = [1]Template.Structs.Navbuttons{
        .{
            .name = "inbox",
            .url = "/inbox",
        },
    };

    if (ctx.uri.next()) |hash| {
        if (hash.len != 64) return error.BadData;

        const gist = Gist.open(ctx.alloc, hash[0..64].*) catch return error.Unknown;
        std.debug.assert(gist.files.len == 1);

        var page = GistPage.init(tmpl, .{
            .meta_head = .{
                .open_graph = .{
                    .title = "Create A New Gist",
                },
            },
            .body_header = .{
                .nav = .{
                    .nav_auth = undefined,
                    .nav_buttons = &btns,
                },
            },
            .gist_body = gist.files[0].blob,
        });

        return ctx.sendPage(&page);
    } else return error.Unrouteable;
}
