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

    // const templates = b.addOptions();
    // templates.addOption(
    //     []const []const u8,
    //     "names",
    //     getTemplates(b) catch @panic("unable to get templates"),
    // );

    // exe.addOptions("templates", templates);
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

    //unit_tests.addOptions("templates", templates);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

/// eventually I'd love to make this comptime but alas
fn getTemplates(b: *std.Build) ![]const []const u8 {
    var cwd = std.fs.cwd();
    var idir = cwd.openIterableDir("templates/", .{}) catch |err| {
        std.debug.print("template build error {}", .{err});
        return &[0][]u8{};
    };
    var itr = idir.iterate();
    var list = std.ArrayList([]const u8).init(b.allocator);
    while (try itr.next()) |file| {
        std.debug.print("file {s}\n", .{file.name});
        try list.append(file.name);
    }
    return try list.toOwnedSlice();
}
