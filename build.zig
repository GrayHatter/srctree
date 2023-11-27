const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "tree",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.linkSystemLibrary2("curl", .{ .preferred_link_mode = .Static });

    addSrcTemplates(exe);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    unit_tests.linkSystemLibrary2("curl", .{ .preferred_link_mode = .Static });

    addSrcTemplates(unit_tests);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

var template_list: ?[][]const u8 = null;

fn buildSrcTemplates(b: *std.Build) ![][]const u8 {
    if (template_list) |tl| return tl;

    const tmplsrcdir = "templates";
    var cwd = std.fs.cwd();
    var idir = cwd.openIterableDir(tmplsrcdir, .{}) catch |err| {
        std.debug.print("template build error {}", .{err});
        return err;
    };
    var arrlist = std.ArrayList([]const u8).init(b.allocator);
    var itr = idir.iterate();
    while (try itr.next()) |file| {
        if (!std.mem.endsWith(u8, file.name, ".html")) continue;
        try arrlist.append(b.pathJoin(&[2][]const u8{ tmplsrcdir, file.name }));
    }
    template_list = try arrlist.toOwnedSlice();
    return template_list.?;
}

/// eventually I'd love to make this comptime but alas
fn addSrcTemplates(cs: *std.Build.Step.Compile) void {
    var b = cs.step.owner;

    var list = buildSrcTemplates(b) catch @panic("unable to build src files");
    const templates = b.addOptions();
    templates.addOption(
        []const []const u8,
        "names",
        list,
    );

    cs.addOptions("templates", templates);

    for (list) |file| {
        cs.addAnonymousModule(file, .{
            .source_file = .{ .path = file },
        });
    }
}
