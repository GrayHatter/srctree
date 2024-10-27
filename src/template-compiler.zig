const std = @import("std");
const compiled = @import("templates-compiled");
const Template = @import("template.zig");
const Allocator = std.mem.Allocator;

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

    alloc: Allocator,
    name: []u8,
    children: []Member,
    child_cap: usize = 0,

    pub fn init(a: Allocator, name: []const u8) !*AbstTree {
        const self = try a.create(AbstTree);
        self.* = .{
            .alloc = a,
            .name = try a.dupe(u8, name),
            .children = try a.alloc(Member, 50),
            .child_cap = 50,
        };
        self.children.len = 0;
        return self;
    }

    pub fn append(self: *AbstTree, name: []const u8, kind: []const u8) !void {
        if (self.children.len >= self.child_cap) @panic("large structs not implemented");

        for (self.children) |child| {
            if (std.mem.eql(u8, child.name, name)) {
                if (!std.mem.eql(u8, child.kind, kind)) {
                    std.debug.print(
                        "Error: kind mismatch {s}.{s} :: {s} != {s}\n",
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
        const this = try AbstTree.init(a, name);
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
            if (Template.Directive.init(data)) |drct| switch (drct.kind) {
                .noun => |noun| {
                    data = data[drct.end..];
                    switch (noun.otherwise) {
                        .ign => {
                            try current.append(makeFieldName(noun.vari), ": []const u8,\n");
                        },
                        .str => |str| {
                            var buffer: [0xFF]u8 = undefined;
                            const kind = try std.fmt.bufPrint(&buffer, ": []const u8 = \"{s}\",\n", .{str});
                            try current.append(makeFieldName(noun.vari), kind);
                        },
                        .del => {
                            try current.append(makeFieldName(noun.vari), ": ?[]const u8 = null,\n");
                        },
                        .template => |_| {
                            var buffer: [0xFF]u8 = undefined;
                            const kind = try std.fmt.bufPrint(&buffer, ": ?{s},\n", .{makeStructName(noun.vari)});
                            try current.append(makeFieldName(noun.vari[1 .. noun.vari.len - 5]), kind);
                        },
                    }
                },
                .verb => |verb| {
                    data = data[drct.end..];
                    const name = makeStructName(verb.vari);
                    const this = try AbstTree.init(a, name);
                    const gop = try tree.getOrPut(this.name);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = this;
                    }

                    switch (verb.word) {
                        .foreach => {
                            var buffer: [0xFF]u8 = undefined;
                            const kind = try std.fmt.bufPrint(&buffer, ": []{s},\n", .{name});
                            try current.append(makeFieldName(verb.vari), kind);
                            try emitVars(a, verb.blob, this);
                        },
                        .with => {
                            var buffer: [0xFF]u8 = undefined;
                            const kind = try std.fmt.bufPrint(&buffer, ": ?{s},\n", .{name});
                            try current.append(makeFieldName(verb.vari), kind);
                            try emitVars(a, verb.blob, this);
                        },
                    }
                },
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
                    local.name[i] = std.ascii.toLower(chr);
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