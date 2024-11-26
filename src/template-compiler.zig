const std = @import("std");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const bufPrint = std.fmt.bufPrint;
const compiled = @import("templates-compiled");
const Template = @import("template.zig");

const AbstTree = struct {
    pub const Member = struct {
        name: []u8,
        kind: []u8,

        pub fn format(self: Member, comptime _: []const u8, _: std.fmt.FormatOptions, w: anytype) !void {
            try w.writeAll("    ");
            try w.writeAll(self.name);
            try w.writeAll(self.kind);
        }
    };

    parent: ?*AbstTree,
    alloc: Allocator,
    name: []u8,
    children: []Member,
    child_cap: usize = 0,

    pub fn init(a: Allocator, name: []const u8, parent: ?*AbstTree) !*AbstTree {
        const self = try a.create(AbstTree);
        self.* = .{
            .parent = parent,
            .alloc = a,
            .name = try a.dupe(u8, name),
            .children = try a.alloc(Member, 50),
            .child_cap = 50,
        };
        self.children.len = 0;
        return self;
    }

    pub fn exists(self: *AbstTree, name: []const u8) bool {
        for (self.children) |child| {
            if (eql(u8, child.name, name)) return true;
        }
        return false;
    }

    pub fn append(self: *AbstTree, name: []const u8, kind: []const u8) !void {
        if (self.children.len >= self.child_cap) @panic("large structs not implemented");

        for (self.children) |child| {
            if (std.mem.eql(u8, child.name, name)) {
                if (!std.mem.eql(u8, child.kind, kind)) {
                    std.debug.print("Error: kind mismatch while building ", .{});
                    var par = self.parent;
                    while (par != null) {
                        par = par.?.parent;
                        std.debug.print("{s}.", .{par.?.name});
                    }

                    std.debug.print(
                        "{s}.{s}\n  {s} != {s}\n",
                        .{ self.name, name, child.kind, kind },
                    );
                    return error.KindMismatch;
                }
                return;
            }
        }

        self.children.len += 1;
        self.children[self.children.len - 1] = .{
            .name = try self.alloc.dupe(u8, name),
            .kind = try self.alloc.dupe(u8, kind),
        };
    }

    pub fn format(self: AbstTree, comptime fmt: []const u8, _: std.fmt.FormatOptions, w: anytype) !void {
        if (comptime std.mem.eql(u8, fmt, "")) {
            try w.writeAll("pub const ");
            try w.writeAll(self.name);
            try w.writeAll(" = struct {\n");
            for (self.children) |child| {
                try w.print("{}", .{child});
            }
            try w.writeAll("};\n");
        } else {
            comptime unreachable;
        }
    }
};

var tree: std.StringHashMap(*AbstTree) = undefined;

pub fn main() !void {
    var args = std.process.args();

    var wout_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        wout_path = arg;
    }

    const a = std.heap.page_allocator;

    const wout_dname = std.fs.path.dirname(wout_path.?) orelse return error.InvalidPath;
    const wout_dir = try std.fs.cwd().openDir(wout_dname, .{});
    var wfile = try wout_dir.createFile(std.fs.path.basename(wout_path.?), .{});
    defer wfile.close();
    try wfile.writeAll(
        \\// Generated by srctree template compiler
        \\
    );
    var wout = wfile.writer();

    tree = std.StringHashMap(*AbstTree).init(a);

    for (compiled.data) |tplt| {
        const fdata = try std.fs.cwd().readFileAlloc(a, tplt.path, 0xffff);
        defer a.free(fdata);

        const name = makeStructName(tplt.path);
        const this = try AbstTree.init(a, name, null);
        const gop = try tree.getOrPut(this.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = this;
        }
        try emitVars(a, fdata, this);
    }

    var itr = tree.iterator();
    while (itr.next()) |each| {
        //std.debug.print("tree: {}\n", .{each.value_ptr.*});
        try wout.print("{}\n", .{each.value_ptr.*});
    }
}

fn emitVars(a: Allocator, fdata: []const u8, current: *AbstTree) !void {
    var data = fdata;
    while (data.len > 0) {
        if (std.mem.indexOf(u8, data, "<")) |offset| {
            data = data[offset..];
            if (Template.Directive.init(data)) |drct| {
                data = data[drct.tag_block.len..];
                const s_name = makeStructName(drct.noun);
                var f_name = makeFieldName(drct.noun);
                switch (drct.verb) {
                    .variable => |_| {
                        var buffer: [0xFF]u8 = undefined;
                        var kind = try bufPrint(&buffer, ": []const u8,\n", .{});

                        switch (drct.otherwise) {
                            .required, .ignore => {},
                            .default => |str| {
                                kind = try bufPrint(&buffer, ": []const u8 = \"{s}\",\n", .{str});
                            },
                            .delete => {
                                kind = try bufPrint(&buffer, ": ?[]const u8 = null,\n", .{});
                            },
                            .template => |_| {
                                kind = try bufPrint(&buffer, ": ?{s},\n", .{s_name});
                                f_name = makeFieldName(drct.noun[1 .. drct.noun.len - 5]);
                            },
                            .blob => unreachable,
                        }
                        if (drct.known_type) |kt| {
                            kind = try bufPrint(&buffer, ": {s},\n", .{@tagName(kt)});
                        }
                        try current.append(f_name, kind);
                    },
                    else => |verb| {
                        var this = try AbstTree.init(a, s_name, current);
                        const gop = try tree.getOrPut(this.name);
                        if (!gop.found_existing) {
                            gop.value_ptr.* = this;
                        } else {
                            this = gop.value_ptr.*;
                        }

                        switch (verb) {
                            .variable => unreachable,
                            .foreach => {
                                var buffer: [0xFF]u8 = undefined;
                                const kind = try bufPrint(&buffer, ": []const {s},\n", .{s_name});
                                try current.append(f_name, kind);
                                try emitVars(a, drct.otherwise.blob, this);
                            },
                            .split => {
                                var buffer: [0xFF]u8 = undefined;
                                const kind = try bufPrint(&buffer, ": []const []const u8,\n", .{});
                                try current.append(f_name, kind);
                            },
                            .with => {
                                var buffer: [0xFF]u8 = undefined;
                                const kind = try bufPrint(&buffer, ": ?{s},\n", .{s_name});
                                try current.append(f_name, kind);
                                try emitVars(a, drct.otherwise.blob, this);
                            },
                            .build => {
                                var buffer: [0xFF]u8 = undefined;
                                const tmpl_name = makeStructName(drct.otherwise.template.name);
                                const kind = try bufPrint(&buffer, ": {s},\n", .{tmpl_name});
                                try current.append(f_name, kind);
                                //try emitVars(a, drct.otherwise.template.blob, this);
                            },
                        }
                    },
                }
            } else if (std.mem.indexOfPos(u8, data, 1, "<")) |next| {
                data = data[next..];
            } else return;
        } else return;
    }
    return;
}

pub fn makeFieldName(in: []const u8) []const u8 {
    const local = struct {
        var name: [0xFFFF]u8 = undefined;
    };

    var i: usize = 0;
    for (in) |chr| {
        switch (chr) {
            'a'...'z' => {
                local.name[i] = chr;
                i += 1;
            },
            'A'...'Z' => {
                if (i != 0) {
                    local.name[i] = '_';
                    i += 1;
                }
                local.name[i] = std.ascii.toLower(chr);
                i += 1;
            },
            '0'...'9' => {
                for (intToWord(chr)) |cchr| {
                    local.name[i] = cchr;
                    i += 1;
                }
            },
            '-', '_', '.' => {
                local.name[i] = '_';
                i += 1;
            },
            else => {},
        }
    }

    return local.name[0..i];
}

pub fn makeStructName(in: []const u8) []const u8 {
    const local = struct {
        var name: [0xFFFF]u8 = undefined;
    };

    var tail = in;

    if (std.mem.lastIndexOf(u8, in, "/")) |i| {
        tail = tail[i..];
    }

    var i: usize = 0;
    var next_upper = true;
    for (tail) |chr| {
        switch (chr) {
            'a'...'z', 'A'...'Z' => {
                if (next_upper) {
                    local.name[i] = std.ascii.toUpper(chr);
                } else {
                    local.name[i] = chr;
                }
                next_upper = false;
                i += 1;
            },
            '0'...'9' => {
                for (intToWord(chr)) |cchr| {
                    local.name[i] = cchr;
                    i += 1;
                }
            },
            '-', '_', '.' => {
                next_upper = true;
            },
            else => {},
        }
    }

    return local.name[0..i];
}

fn intToWord(in: u8) []const u8 {
    return switch (in) {
        '4' => "Four",
        '5' => "Five",
        else => unreachable,
    };
}
