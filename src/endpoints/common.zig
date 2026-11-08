pub fn bodyHeader(f: *Frame) S.BodyHeaderHtml {
    if (f.template_data.get(S.BodyHeaderHtml)) |bh| {
        return bh.*;
    } else {
        return .{
            .inbox_count = search.inboxCount(f.user, f.alloc, f.io),
            .nav_auth = if (f.user) |usr|
                .abx(if (usr.username) |un| un else "Error No Username")
            else
                .safe("Public"),
        };
    }
}

const verse = @import("verse");
const Frame = verse.Frame;
const Router = verse.Router;
const S = verse.template.Structs;
const abx = verse.Antibiotic;
const search = @import("search.zig");
