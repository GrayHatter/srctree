const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_libcurl = b.option(bool, "libcurl", "enable linking with libcurl") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "libcurl", enable_libcurl);

    var binaries = std.ArrayList(*std.Build.Step.Compile).init(b.allocator);
    defer binaries.clearAndFree();

    const templates_compiled = try compileTemplates(b);

    const exe = b.addExecutable(.{
        .name = "srctree",
        .root_source_file = .{
            .path = "src/main.zig",
        },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    binaries.append(exe) catch unreachable;

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
    binaries.append(unit_tests) catch unreachable;

    for (binaries.items) |ex| {
        ex.root_module.addImport("templates-compiled", templates_compiled);
        ex.root_module.addOptions("config", options);
        if (enable_libcurl) {
            ex.linkSystemLibrary2("curl", .{ .preferred_link_mode = .static });
            ex.linkLibC();
        }
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn compileTemplates(b: *std.Build) !*std.Build.Module {
    const compiled = b.addModule("templates-compiled", .{
        .root_source_file = .{
            .path = "src/template-compiled.zig",
        },
    });

    const list = buildSrcTemplates(b) catch @panic("unable to build src files");
    const found = b.addOptions();
    found.addOption(
        []const []const u8,
        "names",
        list,
    );
    compiled.addOptions("found_templates", found);

    for (list) |file| {
        _ = compiled.addAnonymousImport(file, .{
            .root_source_file = .{ .path = file },
        });
    }

    return compiled;
}

var template_list: ?[][]const u8 = null;

fn buildSrcTemplates(b: *std.Build) ![][]const u8 {
    if (template_list) |tl| return tl;

    const tmplsrcdir = "templates";
    var cwd = std.fs.cwd();
    var idir = cwd.openDir(tmplsrcdir, .{ .iterate = true }) catch |err| {
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
