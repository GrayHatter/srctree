const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_libcurl = b.option(bool, "libcurl", "enable linking with libcurl") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "libcurl", enable_libcurl);

    var bins = std.ArrayList(*std.Build.Step.Compile).init(b.allocator);
    defer bins.clearAndFree();

    const comptime_templates = try compileTemplates(b);

    const exe = b.addExecutable(.{
        .name = "srctree",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    bins.append(exe) catch unreachable;

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bins.append(unit_tests) catch unreachable;

    for (bins.items) |ex| {
        ex.root_module.addImport("comptime_templates", comptime_templates);
        ex.root_module.addOptions("config", options);
        if (enable_libcurl) {
            ex.linkSystemLibrary2("curl", .{ .preferred_link_mode = .static });
            ex.linkLibC();
        }
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const t_compiler = b.addExecutable(.{
        .name = "template-compiler",
        .root_source_file = b.path("src/template-compiler.zig"),
        .target = target,
    });

    t_compiler.root_module.addImport("comptime_templates", comptime_templates);
    const tc_build_run = b.addRunArtifact(t_compiler);
    const tc_structs = tc_build_run.addOutputFileArg("compiled-structs.zig");
    const tc_build_step = b.step("templates", "Compile templates down into struct");
    tc_build_step.dependOn(&tc_build_run.step);

    for (bins.items) |bin| bin.root_module.addImport("comptime_template_structs", b.addModule(
        "comptime_template_structs",
        .{ .root_source_file = tc_structs },
    ));

    // Partner Binaries
    const mailer = b.addExecutable(.{
        .name = "srctree-mailer",
        .root_source_file = b.path("src/mailer.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(mailer);

    const send_email = b.addRunArtifact(mailer);
    send_email.step.dependOn(b.getInstallStep());
    const send_email_step = b.step("email", "send an email");
    send_email_step.dependOn(&send_email.step);
    if (b.args) |args| {
        send_email.addArgs(args);
    }
}

fn compileTemplates(b: *std.Build) !*std.Build.Module {
    const compiled = b.addModule("comptime_templates", .{
        .root_source_file = b.path("src/template/comptime.zig"),
    });

    const list = buildSrcTemplates(b) catch @panic("unable to build src files");
    const found = b.addOptions();
    found.addOption([]const []const u8, "names", list);
    compiled.addOptions("config", found);

    for (list) |file| {
        _ = compiled.addAnonymousImport(file, .{
            .root_source_file = b.path(file),
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
