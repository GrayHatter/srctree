const std = @import("std");

const Endpoint = @import("../endpoint.zig");
const Response = Endpoint.Response;
const HTML = Endpoint.HTML;
const Template = Endpoint.Template;
const DateTime = @import("../datetime.zig");

const Error = Endpoint.Error;

pub fn commitFlex(r: *Response, _: []const u8) Error!void {
    var tmpl = Template.find("user_commits.html");
    tmpl.alloc = r.alloc;

    HTML.init(r.alloc);
    defer HTML.raze();

    const day = [1]HTML.Attribute{HTML.Attribute.class("day")};
    const monthAtt = [1]HTML.Attribute{HTML.Attribute.class("month")};

    var date = DateTime.now();
    var month_i: usize = date.months - 1;
    var stack: [53]HTML.Element = undefined;
    for (&stack, 0..) |*st, i| {
        var month: []HTML.Element = try r.alloc.alloc(HTML.Element, 8);
        if (i % 4 == 0) {
            month[0] = HTML.divAttr(DateTime.MONTHS[month_i % 12 + 1][0..3], &monthAtt);
            month_i += 1;
        } else {
            month[0] = HTML.divAttr(null, &monthAtt);
        }

        for (month[1..]) |*m| {
            m.* = HTML.divAttr(null, &day);
        }
        st.* = HTML.divAttr(month, &[1]HTML.Attribute{HTML.Attribute.class("col")});
    }
    defer for (stack) |s| r.alloc.free(s.children.?);

    var now = DateTime.now();
    std.debug.print("{any}\n", .{now});

    std.debug.print("{}\n", .{DateTime.DAYS_IN_MONTH[now.months] - (now.days - now.weekday)});

    var days = &[_]HTML.Element{
        HTML.divAttr(&[_]HTML.Element{
            HTML.divAttr("&nbsp;", &day),
            HTML.divAttr("Sun", &day),
            HTML.divAttr("Mon", &day),
            HTML.divAttr("Tue", &day),
            HTML.divAttr("Wed", &day),
            HTML.divAttr("Thr", &day),
            HTML.divAttr("Fri", &day),
            HTML.divAttr("Sat", &day),
        }, &[1]HTML.Attribute{HTML.Attribute.class("day-col")}),
    };

    const flex = HTML.divAttr(
        days ++ stack,
        &[1]HTML.Attribute{HTML.Attribute.class("commit-flex")},
    );

    const htm = try std.fmt.allocPrint(r.alloc, "{}", .{flex});
    defer r.alloc.free(htm);

    tmpl.addVar("flexes", htm) catch return Error.Unknown;

    var page = std.fmt.allocPrint(r.alloc, "{}", .{tmpl}) catch unreachable;
    r.start() catch return Error.Unknown;
    r.write(page) catch return Error.Unknown;
    r.finish() catch return Error.Unknown;
}
