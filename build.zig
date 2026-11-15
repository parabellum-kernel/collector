const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const common_mod = b.addModule("collectors_common", .{
        .root_source_file = b.path("common/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    const webhook_mod = b.createModule(.{
        .root_source_file = b.path("webhook_receiver/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    webhook_mod.addImport("collectors_common", common_mod);
    const webhook_exe = b.addExecutable(.{
        .name = "parabellum-collector-webhook",
        .root_module = webhook_mod,
    });
    b.installArtifact(webhook_exe);

    const filewatcher_mod = b.createModule(.{
        .root_source_file = b.path("file_watcher/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    filewatcher_mod.addImport("collectors_common", common_mod);
    const filewatcher_exe = b.addExecutable(.{
        .name = "parabellum-collector-filewatcher",
        .root_module = filewatcher_mod,
    });
    b.installArtifact(filewatcher_exe);

    const test_step = b.step("test", "Run collectors unit tests");
    const run_t = b.addRunArtifact(b.addTest(.{ .root_module = common_mod }));
    test_step.dependOn(&run_t.step);
}

