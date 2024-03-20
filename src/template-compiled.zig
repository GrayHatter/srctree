const found = @import("found_templates");

const TEMPLATE_PATH = "templates/";

pub const FileData = struct {
    path: []const u8,
    blob: []const u8,
};

pub const data: [found.names.len]FileData = blk: {
    @setEvalBranchQuota(5000);
    var t: [found.names.len]FileData = undefined;
    for (found.names, &t) |file, *dst| {
        dst.* = FileData{
            .path = file,
            .blob = @embedFile(file),
        };
    }
    break :blk t;
};
