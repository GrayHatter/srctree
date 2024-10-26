const Found = @import("found_templates");
const PageData = @import("pagedata");

const TEMPLATE_PATH = "templates/";

pub const FileData = struct {
    path: []const u8,
    blob: []const u8,
};

pub const data: [Found.names.len]FileData = blk: {
    @setEvalBranchQuota(5000);
    var t: [Found.names.len]FileData = undefined;
    for (Found.names, &t) |file, *dst| {
        dst.* = FileData{
            .path = file,
            .blob = @embedFile(file),
        };
    }
    break :blk t;
};
