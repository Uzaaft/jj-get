const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("jj_get", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe_options = b.addOptions();
    exe_options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const exe = b.addExecutable(.{
        .name = "jj-get",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "jj_get", .module = mod },
                .{ .name = "build_options", .module = exe_options.createModule() },
            },
        }),
    });
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    // jj-list is the same binary under another name; it picks its
    // behavior from argv[0].
    const list_link = b.addSystemCommand(&.{ "ln", "-sf", exe.out_filename, b.getInstallPath(.bin, "jj-list") });
    list_link.has_side_effects = true;
    list_link.step.dependOn(&install_exe.step);
    b.getInstallStep().dependOn(&list_link.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run jj-get").dependOn(&run_cmd.step);

    const unit_tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    const unit_step = b.step("test-unit", "Run unit tests");
    unit_step.dependOn(&unit_tests.step);

    // End-to-end tests drive the built binary against local repositories,
    // so they need jj and git on PATH.
    const e2e_options = b.addOptions();
    e2e_options.addOptionPath("jj_get", exe.getEmittedBin());
    const e2e_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = e2e_options.createModule() },
            },
        }),
    }));
    const e2e_step = b.step("test-e2e", "Run end-to-end tests");
    e2e_step.dependOn(&e2e_tests.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(unit_step);
    test_step.dependOn(e2e_step);
}
