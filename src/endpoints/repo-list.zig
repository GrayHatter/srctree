const std = @import("std");

const Endpoint = @import("../endpoint.zig");
const Response = Endpoint.Response;
const HTML = Endpoint.HTML;
const Template = Endpoint.Template;

const git = @import("../git.zig");

const Error = Endpoint.Error;

fn sorter(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}

pub fn list(r: *Response, _: []const u8) Error!void {
    var cwd = std.fs.cwd();
    if (cwd.openIterableDir("./repos", .{})) |idir| {
        var flist = std.ArrayList([]u8).init(r.alloc);
        var itr = idir.iterate();
        while (itr.next() catch return Error.Unknown) |file| {
            if (file.kind != .directory and file.kind != .sym_link) continue;
            if (file.name[0] == '.') continue;
            try flist.append(try r.alloc.dupe(u8, file.name));
        }
        std.sort.heap([]u8, flist.items, {}, sorter);

        var repos = try r.alloc.alloc(HTML.E, flist.items.len);
        for (repos, flist.items) |*repoln, name| {
            var attr = try r.alloc.dupe(
                HTML.Attribute,
                &[_]HTML.Attribute{.{
                    .key = "href",
                    .value = try std.fmt.allocPrint(r.alloc, "/repo/{s}", .{name}),
                }},
            );
            var anc = try r.alloc.dupe(HTML.E, &[_]HTML.E{HTML.anch(name, attr)});
            repoln.* = HTML.li(anc, null);
        }

        var tmpl = Template.find("repos.html");
        tmpl.init(r.alloc);
        const repo = try std.fmt.allocPrint(r.alloc, "{}", .{HTML.element("repos", repos, null)});
        tmpl.addVar("repos", repo) catch return Error.Unknown;

        var page = tmpl.buildFor(r.alloc, r) catch unreachable;
        r.start() catch return Error.Unknown;
        r.write(page) catch return Error.Unknown;
        r.finish() catch return Error.Unknown;
    } else |err| {
        std.debug.print("unable to open given dir {}\n", .{err});
        return;
    }
}

pub fn tree(r: *Response, uri: []const u8) Error!void {
    r.status = .ok;

    var cwd = std.fs.cwd();
    var filename = try std.fmt.allocPrint(r.alloc, "./repos/{s}", .{uri[6..]});
    var dir = cwd.openDir(filename, .{}) catch return error.Unknown;
    var repo = git.Repo.init(dir) catch return error.Unknown;

    var tmpl = Template.find("repo.html");
    tmpl.init(r.alloc);

    var head = repo.HEAD(r.alloc) catch return error.Unknown;
    tmpl.addVar("branch.default", head.branch.name) catch return error.Unknown;

    var refs = repo.refs(r.alloc) catch return error.Unknown;
    var a_refs = try r.alloc.alloc([]const u8, refs.len);
    for (a_refs, refs) |*dst, src| {
        dst.* = src.branch.name;
    }
    var str_refs = try std.mem.join(r.alloc, "\n", a_refs);
    tmpl.addVar("branches", str_refs) catch return error.Unknown;

    var files = repo.tree(r.alloc) catch return error.Unknown;
    var a_files = try r.alloc.alloc(HTML.E, files.objects.len);
    for (a_files, files.objects) |*dst, src| {
        dst.* = HTML.element("file", src.name, null);
    }

    const filestr = try std.fmt.allocPrint(r.alloc, "{}", .{HTML.div(a_files)});
    tmpl.addVar("files", filestr) catch return error.Unknown;

    var page = tmpl.buildFor(r.alloc, r) catch unreachable;

    r.start() catch return Error.Unknown;
    r.write(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}
