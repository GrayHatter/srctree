const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_libcurl = b.option(bool, "libcurl", "enable linking with libcurl") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "libcurl", enable_libcurl);
    const use_llvm = optimize != .Debug or true;

    // Dependencies
    const verse = b.dependency("verse", .{
        .target = target,
        .optimize = optimize,
        .@"template-path" = b.path("templates"),
        .@"ua-validation" = true,
        .@"abx-required" = true,
        .@"accept-lang-heat" = "",
    });

    const smtp = b.dependency("smtp", .{
        .target = target,
        .optimize = optimize,
    });

    // Set up verse
    const mod_verse = verse.module("verse");
    const mod_smtp = smtp.module("smtp");

    // srctree
    const exe = b.addExecutable(.{
        .name = "srctree",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    b.installArtifact(exe);
    exe.root_module.addOptions("config", options);
    exe.root_module.addImport("verse", mod_verse);
    exe.root_module.addImport("smtp", mod_smtp);

    // build run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // srctree tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    unit_tests.root_module.addOptions("config", options);
    unit_tests.root_module.addImport("verse", mod_verse);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const deploy = b.step("deploy", "insall exes & static files");
    const deploy_bin = b.addInstallArtifact(exe, .{});
    deploy.dependOn(&deploy_bin.step);
    const static_files = b.addInstallDirectory(.{
        .source_dir = b.path("static"),
        .install_dir = .prefix,
        .install_subdir = "static",
    });
    deploy.dependOn(&static_files.step);

    // Partner Binaries
    //const maild = b.addExecutable(.{
    //    .name = "srctree-maild",
    //    .root_module = b.createModule(.{
    //        .root_source_file = b.path("src/mailer.zig"),
    //        .target = target,
    //        .optimize = optimize,
    //    }),
    //    .use_llvm = use_llvm,
    //    .use_lld = use_llvm,
    //});
    //b.installArtifact(maild);

    //const send_email = b.addRunArtifact(maild);
    //send_email.step.dependOn(b.getInstallStep());
    //const send_email_step = b.step("email", "send an email");
    //send_email_step.dependOn(&send_email.step);
    //if (b.args) |args| {
    //    send_email.addArgs(args);
    //}
}
