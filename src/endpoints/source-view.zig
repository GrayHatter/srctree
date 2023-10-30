const std = @import("std");

const Endpoint = @import("../endpoint.zig");
const Response = Endpoint.Response;
const HTML = Endpoint.HTML;
const Template = Endpoint.Template;

const Error = Endpoint.Error;

const span = HTML.span;

pub fn code(r: *Response, _: *Endpoint.UriIter) Error!void {
    HTML.init(r.alloc);
    defer HTML.raze();

    const src = @embedFile(@src().file[14..]);
    const count = std.mem.count(u8, src, "\n");

    var linens = try r.alloc.alloc([]u8, count + 1);
    for (0..count + 1) |i| {
        linens[i] = try std.fmt.allocPrint(r.alloc, "<ln num=\"{}\"></ln>", .{i + 1});
    }
    var lnums = try std.mem.join(r.alloc, "", linens);

    var lines = try r.alloc.alloc([]u8, count + 1);
    var itr = std.mem.split(u8, src, "\n");
    var i: usize = 0;
    while (itr.next()) |line| {
        lines[i] = try std.fmt.allocPrint(r.alloc, "{}\n", .{span(HTML.text(line))});
        i += 1;
    }
    // TODO better API to avoid join
    var joined = try std.mem.join(r.alloc, "", lines);

    var tmpl = Template.find("code.html");
    tmpl.init(r.alloc);

    tmpl.addVar("lines", lnums) catch return Error.Unknown;
    tmpl.addVar("code", joined) catch return Error.Unknown;
    //var page = tmpl.build(r.alloc) catch unreachable;
    var page = tmpl.buildFor(r.alloc, r) catch unreachable;

    r.start() catch return Error.Unknown;
    r.write(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}
