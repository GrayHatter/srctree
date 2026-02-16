pub const verse_name = .issues;

pub const verse_aliases = .{
    .issue,
};

pub const verse_router: Router.RouteFn = router;

pub const routes = [_]Router.Match{
    ROUTE("", list),
    GET("new", new),
    GET("new-remote", newRemote),
    POST("new", newPost),
    POST("new-remote", newRemotePost),
    POST("add-comment", addComment),
};

pub const index = list;

fn isHex(input: []const u8) ?usize {
    for (input) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return std.fmt.parseInt(usize, input, 16) catch null;
}

pub fn router(ctx: *verse.Frame) Router.RoutingError!Router.BuildFn {
    const current = ctx.uri.next() orelse return error.Unrouteable;
    if (!eql(u8, "issues", current) and !eql(u8, "issue", current)) return error.Unrouteable;
    const verb = ctx.uri.peek() orelse return Router.defaultRouter(ctx, &routes);

    if (isHex(verb)) |_| {
        return view;
    }

    return Router.defaultRouter(ctx, &routes);
}

const IssueNewPage = T.PageData("issue-new.html");

fn new(ctx: *verse.Frame) Error!void {
    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };

    var body_header: S.BodyHeaderHtml = .{ .nav = .{ .nav_buttons = &try repos_ep.navButtons(ctx) } };
    if (ctx.user) |usr| {
        body_header.nav.nav_auth = usr.username.?;
    }
    var page = IssueNewPage.init(.{
        .meta_head = meta_head,
        .body_header = body_header,
        .flavor = .{ .default = .{} },
    });
    try ctx.sendPage(&page);
}

fn newRemote(ctx: *verse.Frame) Error!void {
    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };

    var body_header: S.BodyHeaderHtml = .{ .nav = .{ .nav_buttons = &try repos_ep.navButtons(ctx) } };
    if (ctx.user) |usr| {
        body_header.nav.nav_auth = usr.username.?;
    }
    var page = IssueNewPage.init(.{
        .meta_head = meta_head,
        .body_header = body_header,
        .flavor = .{ .remote = .{} },
    });
    try ctx.sendPage(&page);
}

const IssueCreateReq = struct {
    title: []const u8,
    desc: []const u8,

    remote: ?bool,
    submit: ?bool,
    preview: ?bool,

    pub fn validate(icr: IssueCreateReq) !void {
        if (icr.title.len < 4) return error.TitleTooShort;
    }
};

fn newPostError(_: *verse.Frame) Error!void {
    // TODO create error page
    return error.DataInvalid;
}

fn newPost(f: *verse.Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    var buf: [2048]u8 = undefined;
    if (f.request.data.post) |post| {
        const valid = post.validate(IssueCreateReq) catch return error.DataInvalid;
        if (valid.remote) |_| return newRemote(f);

        valid.validate() catch |err| switch (err) {
            error.TitleTooShort => try newPostError(f),
        };

        var delta = Delta.new(rd.name, valid.title, valid.desc, if (f.user) |usr|
            usr.username.?
        else
            try allocPrint(f.alloc, "remote_address", .{}), f.io) catch unreachable;

        delta.attach = .issue;
        delta.commit(f.io) catch unreachable;

        const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, delta.index });
        return f.redirect(loc, .see_other) catch unreachable;
    }

    const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issue/new", .{rd.name});
    return f.redirect(loc, .see_other) catch unreachable;
}

const RemoteIssueCreateReq = struct {
    uri: []const u8,

    new: ?bool,
    submit: ?bool,
};

const RemoteData = struct {
    title: []const u8,
    description: []const u8,
    author: []const u8,

    comments: [][]u8,
};

fn newRemotePost(f: *verse.Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    var buf: [2048]u8 = undefined;
    if (f.request.data.post) |post| {
        const valid = post.validate(RemoteIssueCreateReq) catch return error.DataInvalid;
        if (valid.new) |_| return new(f);

        return fromRemoteUri(f, rd.name, valid.uri) catch return error.Unknown;
    }

    const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issue/new", .{rd.name});
    return f.redirect(loc, .see_other) catch unreachable;
}

const AddCommentReq = struct {
    comment: []const u8,
    did: []const u8,
};

fn addComment(f: *verse.Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    const post = f.request.data.post orelse return error.DataMissing;
    const validate = post.validate(AddCommentReq) catch return error.DataInvalid;

    const did: usize = std.fmt.parseInt(usize, validate.did, 16) catch return error.DataInvalid;

    var delta = Delta.open(rd.name, did, f.alloc, f.io) catch
        return error.Unknown;
    const username = if (f.user) |usr| usr.username.? else "public";

    _ = delta.addComment(.{ .author = username, .message = validate.comment }, f.alloc, f.io) catch {};
    var buf: [2048]u8 = undefined;
    const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ rd.name, did });
    f.redirect(loc, .see_other) catch unreachable;
    return;
}

const DeltaIssuePage = T.PageData("delta-issue.html");

fn view(f: *verse.Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    const delta_id = f.uri.next().?;
    const idx = isHex(delta_id) orelse return error.Unrouteable;

    const vis: repos.Visibility.Select = if (f.user) |_| .all else .public_only;
    var repo = (repos.open(rd.name, vis, f.io) catch return error.DataInvalid) orelse return error.DataInvalid;
    defer repo.raze(f.alloc, f.io);
    var delta = Delta.open(rd.name, idx, f.alloc, f.io) catch return error.Unrouteable;

    const messages = try delta_shared.genThreadMessages(&delta, &repo, null, f.alloc, f.io);

    var r: Reader = .fixed(delta.message);
    var w: Writer.Allocating = try .initCapacity(f.alloc, delta.message.len);
    Highlight.Markdown.translate(&r, &w.writer, f.alloc, f.io) catch |err| switch (err) {
        error.OutOfMemory, error.WriteFailed => return error.ServerFault,
        error.InvalidMarkdown => try w.writer.print("{f}", .{abx.Html{ .text = delta.message }}),
    };
    const description = w.written();

    const username = if (f.user) |usr| usr.username.? else "anon";
    const meta_head = S.MetaHeadHtml{ .open_graph = .{} };

    var body_header: S.BodyHeaderHtml = .{ .nav = .{ .nav_buttons = &try repos_ep.navButtons(f) } };
    if (f.user) |usr| {
        body_header.nav.nav_auth = usr.username.?;
    }

    const status: []const u8 = if (delta.state.closed)
        "<span class=closed>closed</span>"
    else
        "<span class=open>open</span>";

    const now: i64 = Io.Clock.real.now(f.io).toSeconds();
    var page = DeltaIssuePage.init(.{
        .meta_head = meta_head,
        .body_header = body_header,
        .repo_header = .{
            .repo_name = rd.name,
            .description = "",
            .blame = null,
            .git_uri = null,
            .upstream = null,
        },
        .title = allocPrint(f.alloc, "{f}", .{verse.abx.Html{ .text = delta.title }}) catch unreachable,
        .description = description,
        .creator = if (delta.author) |author| try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = author }}) else null,
        .status = status,
        .created = try allocPrint(f.alloc, "{f}", .{Humanize.unix(delta.created, now)}),
        .updated = try allocPrint(f.alloc, "{f}", .{Humanize.unix(delta.updated, now)}),
        .comments = .{ .messages = messages },
        .comment_box = .{ .current_username = username, .delta_id = delta_id },
        .tracking_remote = if (delta.attach == .remote)
            .{ .url = try allocPrint(f.alloc, "{f}", .{abx.Html{ .text = delta.attach_remote }}) }
        else
            null,
    });
    // required because linux will validate data.[slice].ptr and zig likes to
    // pretend that setting .ptr = undefined when .len == 0
    if (page.data.title.len == 0) {
        page.data.title = "[No Title]";
    }

    if (page.data.description.len == 0) {
        page.data.description = "<span class=\"muted\">No description provided</span>";
    }

    try f.sendPage(&page);
}

fn list(f: *Frame) Error!void {
    const rd = RouteData.init(f.uri) orelse return error.Unrouteable;
    const rules = try search.genRules("is:issue", f.alloc);
    var itr = Delta.searchRepo(rd.name, rules.items, f.io);
    var default_search_buf: [0xFF]u8 = undefined;
    const def_search = try bufPrint(&default_search_buf, "repo:{s} is:issue", .{rd.name});

    var body_header: S.BodyHeaderHtml = .{ .nav = .{ .nav_buttons = &(repos_ep.navButtons(f) catch unreachable) } };
    if (f.user) |usr| body_header.nav.nav_auth = usr.username.?;
    f.response_data.add(S.BodyHeaderHtml, f.alloc, &body_header) catch {};

    return delta_shared.list(f, Delta.RepoIterator, &itr, def_search);
}

pub const RemoteForge = enum {
    codeberg,
    github,

    pub fn fromHost(host: []const u8) ?RemoteForge {
        if (eql(u8, host, "codeberg.org")) {
            return .codeberg;
        }
        if (eql(u8, host, "github.com")) {
            return .github;
        }
        return null;
    }
};

pub const SupportedRemotes = union(RemoteForge) {
    codeberg: Forgejo,
    github: Github,

    pub fn fromHost(uri: std.Uri) !SupportedRemotes {
        const host = uri.host orelse return error.NoHost;
        return switch (RemoteForge.fromHost(host.percent_encoded) orelse return error.Unsupported) {
            .codeberg => .{ .codeberg = .{} },
            .github => .{ .github = .{} },
        };
    }

    pub const Forgejo = struct {
        pub const IssueJson = struct {
            id: usize,
            number: usize,
            title: []const u8,
            body: []const u8,
            user: User,
            labels: []const Label,
            state: []const u8,
            comments: usize,
            created_at: []const u8,
            updated_at: []const u8,
            closed_at: []const u8,
            //milestone: ?Milestone = null,

            pub const Label = struct {
                id: usize,
                name: []const u8,
            };

            pub const User = struct {
                login: []const u8,
                username: []const u8,
            };

            pub const Milestone = struct {
                id: usize,
                title: []const u8,
                description: []const u8,
                state: []const u8,
                created_at: []const u8,
                updated_at: []const u8,
            };
        };

        fn buildUri(uri: std.Uri, buffer: []u8) !std.Uri {
            var api = uri;
            const api_path = try bufPrint(buffer, "/api/v1/repos{s}", .{api.path.percent_encoded});
            api.path = .{ .percent_encoded = api_path };
            return api;
        }

        pub fn getIssue(uri: std.Uri, a: Allocator, io: Io) !RemoteData {
            var path_buffer: [2048]u8 = undefined;
            const api = try buildUri(uri, &path_buffer);
            var w: Io.Writer.Allocating = .init(a);

            var client: std.http.Client = .{ .allocator = a, .io = io };
            const page = try client.fetch(.{ .location = .{ .uri = api }, .response_writer = &w.writer });
            if (page.status != .ok) {
                log.err("Unable to clone from remote repo:  {} [{f}]", .{ page.status, uri.fmt(.all) });
                return error.RequestFailed;
            }

            const page_text = w.written();
            std.debug.print("page \n\n\n{s}\n\n", .{page_text});
            const json: IssueJson = (try std.json.parseFromSlice(IssueJson, a, page_text, .{
                .ignore_unknown_fields = true,
            })).value;

            return .{
                .title = json.title,
                .description = json.body,
                .author = json.user.username,
                .comments = &.{}, // TODO query comments too! /api/v1/group/repo/issues/id/comments
            };
        }
    };

    pub const Github = struct {
        pub const IssueJson = struct {
            id: usize,
            number: usize,
            title: []const u8,
            body: []const u8,
            user: User,
            labels: []const Label,
            state: []const u8,
            comments: usize,
            created_at: ?[]const u8,
            updated_at: ?[]const u8,
            closed_at: ?[]const u8,

            pub const Label = struct {
                id: usize,
                name: []const u8,
            };

            pub const User = struct {
                login: []const u8,
            };

            pub const Milestone = struct {
                id: usize,
                title: []const u8,
                description: []const u8,
                state: []const u8,
                created_at: []const u8,
                updated_at: []const u8,
            };
        };

        fn buildUri(uri: std.Uri, buffer: []u8) !std.Uri {
            const Str = struct {
                const host: []const u8 = "api.github.com";
            };
            var api = uri;
            const api_path = try bufPrint(buffer, "/repos{s}", .{api.path.percent_encoded});
            api.host = .{ .percent_encoded = Str.host };
            api.path = .{ .percent_encoded = api_path };
            return api;
        }

        pub fn getIssue(uri: std.Uri, a: Allocator, io: Io) !RemoteData {
            var path_buffer: [2048]u8 = undefined;
            const api = try buildUri(uri, &path_buffer);
            var w: Io.Writer.Allocating = .init(a);

            var client: std.http.Client = .{ .allocator = a, .io = io };
            const page = try client.fetch(.{ .location = .{ .uri = api }, .response_writer = &w.writer });
            if (page.status != .ok) {
                log.err("Unable to clone from remote repo:  {} [{f}]", .{ page.status, uri.fmt(.all) });
                return error.RequestFailed;
            }

            const page_text = w.written();
            std.debug.print("page \n\n\n{s}\n\n", .{page_text});
            const json: IssueJson = (try std.json.parseFromSlice(IssueJson, a, page_text, .{
                .ignore_unknown_fields = true,
            })).value;

            return .{
                .title = json.title,
                .description = json.body,
                .author = json.user.login,
                .comments = &.{}, // TODO query comments too! /api/v1/group/repo/issues/id/comments
            };
        }
    };
};

fn fromRemoteUri(f: *Frame, repo_name: []const u8, uri_str: []const u8) !void {
    const uri: std.Uri = try .parse(uri_str);
    const remote: SupportedRemotes = try .fromHost(uri);

    const data: RemoteData = switch (remote) {
        .codeberg => |cb| try @TypeOf(cb).getIssue(uri, f.alloc, f.io),
        .github => |gh| try @TypeOf(gh).getIssue(uri, f.alloc, f.io),
    };

    var delta = Delta.new(repo_name, data.title, data.description, if (f.user) |usr|
        usr.username.?
    else
        try allocPrint(f.alloc, "remote_address", .{}), f.io) catch unreachable;

    delta.attach = .remote;
    delta.attach_remote = uri_str;
    delta.commit(f.io) catch unreachable;

    var buf: [2048]u8 = undefined;
    const loc = try std.fmt.bufPrint(&buf, "/repo/{s}/issues/{x}", .{ repo_name, delta.index });
    return f.redirect(loc, .see_other) catch unreachable;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const eql = std.mem.eql;
const findPos = std.mem.findPos;
const find = std.mem.find;
const log = std.log.scoped(.verse_issue);

const verse = @import("verse");
const Frame = verse.Frame;
const abx = verse.abx;
const Router = verse.Router;
const T = verse.template;
const Error = Router.Error;
const ROUTE = Router.ROUTE;
const POST = Router.POST;
const GET = Router.GET;
const S = T.Structs;

const repos = @import("../../repos.zig");
const repos_ep = @import("../repos.zig");
const RouteData = @import("../repos.zig").RouteData;

const search = @import("../search.zig");
const delta_shared = @import("../delta.zig");

const Types = @import("../../types.zig");
const Delta = Types.Delta;
const Humanize = @import("../../humanize.zig");
const Highlight = @import("../../syntax-highlight.zig");
