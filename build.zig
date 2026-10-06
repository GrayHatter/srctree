const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = optimize != .debug or false;

    const full_ci = b.option(bool, "fullci", "enable full CI tests") orelse false;
    const ci_cache_path = b.option([]const u8, "ci_cache_path", "path to store the CI tests cache");

    const options = b.addOptions();
    options.addOption(bool, "full_ci", full_ci);
    options.addOption(?[]const u8, "ci_cache_path", ci_cache_path);

    //const predir = b.root.openDir(b.graph.io, ".", .{ .iterate = true }) catch @panic("bah");
    //var buf: [4000]u8 = undefined;
    //const real = buf[0 .. predir.realPath(b.graph.io, &buf) catch unreachable];
    //std.debug.print("realpath {s}\n\n", .{real});

    const verse = b.dependency("verse", .{
        .target = target,
        .optimize = optimize,
        .templates = findTemplates("templates", b, b.allocator, b.graph.io) catch unreachable,
        .@"ua-validation" = true,
        .@"abx-required" = true,
        .@"accept-lang-heat" = "",
    });
    const verse_mod = verse.module("verse");

    const smtp = b.dependency("smtp", .{ .target = target, .optimize = optimize });
    const smtp_mod = smtp.module("smtp");

    // srctree
    const srctree_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });
    const srctree = b.addExecutable(.{
        .name = "srctree",
        .root_module = srctree_mod,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    b.installArtifact(srctree);
    srctree_mod.addOptions("config", options);
    srctree_mod.addImport("verse", verse_mod);
    srctree_mod.addImport("smtp", smtp_mod);

    // build run
    const run_cmd = b.addRunArtifact(srctree);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "run srctree");
    run_step.dependOn(&run_cmd.step);

    // srctree tests
    const unit_tests = b.addTest(.{ .root_module = srctree_mod, .use_llvm = use_llvm, .use_lld = use_llvm });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Partner Binaries
    //const maild_mod = b.createModule(.{
    //    .root_source_file = b.path("src/mailer.zig"),
    //    .target = target,
    //});
    //const maild = b.addExecutable(.{
    //    .name = "srctree-maild",
    //    .root_module = maild_mod,
    //    .use_llvm = use_llvm,
    //    .use_lld = use_llvm,
    //});
    //b.installArtifact(maild);

    const hooks_mod = b.createModule(.{ .root_source_file = b.path("src/hooks.zig"), .target = target });
    const hooks = b.addExecutable(.{ .name = "srctree-hooks", .root_module = hooks_mod });
    const hook_artifact = b.addInstallArtifact(hooks, .{ .dest_sub_path = "hooks/update" });
    b.getInstallStep().dependOn(&hook_artifact.step);

    const artificer_mod = b.createModule(.{
        .root_source_file = b.path("src/Artificer.zig"),
        .target = target,
    });
    const artificer = b.addExecutable(.{ .name = "artificer", .root_module = artificer_mod });
    const artificer_artifact = b.addInstallArtifact(artificer, .{});
    b.getInstallStep().dependOn(&artificer_artifact.step);

    const deploy = b.step("deploy", "install all artifacts");
    const static_files = b.addInstallDirectory(.{
        .source_dir = b.path("static"),
        .install_dir = .prefix,
        .install_subdir = "static",
    });
    const deploy_exe = b.addInstallArtifact(srctree, .{});
    deploy.dependOn(&deploy_exe.step);
    deploy.dependOn(&hook_artifact.step);
    deploy.dependOn(&artificer_artifact.step);
    deploy.dependOn(&static_files.step);
}

fn findTemplates(path: []const u8, b: *std.Build, a: std.mem.Allocator, io: std.Io) ![]const std.Build.LazyPath {
    var list: std.ArrayList(std.Build.LazyPath) = .empty;

    const dir = b.root.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        else => @panic("unable to open template dir"),
    };
    defer dir.close(io);
    const starting: std.Build.LazyPath = b.path(path);

    var itr = dir.walk(a) catch @panic("OOM");
    while (itr.next(io) catch @panic("IO")) |file| {
        switch (file.kind) {
            .file => if (std.mem.endsWith(u8, file.basename, ".html")) {
                //std.debug.print("basename {s}\n", .{file.basename});
                const new = starting.path(b, a.dupe(u8, file.path) catch @panic("OOM"));
                list.append(a, new) catch @panic("OOM");
            },
            .directory => {},
            else => {},
        }
    }

    return try list.toOwnedSlice(a);
}
