const std = @import("std");

const Compiler = @import("verse").Compiler;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_libcurl = b.option(bool, "libcurl", "enable linking with libcurl") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "libcurl", enable_libcurl);

    var bins = std.ArrayList(*std.Build.Step.Compile).init(b.allocator);
    defer bins.clearAndFree();

    const verse = b.dependency("verse", .{
        .target = target,
        .optimize = optimize,
    });

    const comptime_templates = Compiler.buildTemplates(b, "templates") catch unreachable;
    const comptime_structs = Compiler.buildStructs(b, "templates") catch unreachable;
    const verse_module = verse.module("verse");
    verse_module.addImport("comptime_templates", comptime_templates);
    verse_module.addImport("comptime_structs", comptime_structs);

    const exe = b.addExecutable(.{
        .name = "srctree",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    bins.append(exe) catch unreachable;

    exe.root_module.addImport("verse", verse_module);
    //exe.linkLibrary(verse.artifact("verse"));

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
    unit_tests.root_module.addImport("verse", verse_module);
    bins.append(unit_tests) catch unreachable;

    for (bins.items) |ex| {
        ex.root_module.addImport("comptime_templates", comptime_templates);
        ex.root_module.addImport("comptime_structs", comptime_templates);
        ex.root_module.addOptions("config", options);
        if (enable_libcurl) {
            ex.linkSystemLibrary2("curl", .{ .preferred_link_mode = .static });
            ex.linkLibC();
        }
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    //for (bins.items) |bin| bin.root_module.addImport("comptime_template_structs", b.addModule(
    //    "comptime_template_structs",
    //    .{ .root_source_file = tc_structs },
    //));

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
