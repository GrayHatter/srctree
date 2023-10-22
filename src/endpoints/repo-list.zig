const std = @import("std");

const Endpoint = @import("../endpoint.zig");
const Response = Endpoint.Response;
const HTML = Endpoint.HTML;
const Template = Endpoint.Template;

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