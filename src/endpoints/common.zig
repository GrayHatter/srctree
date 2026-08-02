pub fn bodyHeader(f: *Frame) S.BodyHeaderHtml {
    if (f.response_data.get(S.BodyHeaderHtml)) |bh| {
        return bh.*;
    } else {
        return .{ .nav = .{ .nav_buttons = &.{} } };
    }
}

const verse = @import("verse");
const Frame = verse.Frame;
const Router = verse.Router;
const S = verse.template.Structs;
const abx = verse.Antibiotic;
