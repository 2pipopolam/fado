const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis_dep = b.dependency("vaxis", .{});
    const vaxis_mod = vaxis_dep.module("vaxis");

    const exe = b.addExecutable(.{
        .name = "fado",
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // impl vaxis
    exe.root_module.addImport("vaxis", vaxis_mod);

    // minimp3 implementation
    exe.addCSourceFile(.{
        .file = .{ .cwd_relative = "lib/minimp3_impl.c" },
        .flags = &[_][]const u8{"-std=c99"},
    });

    // Include path for minimp3
    exe.addIncludePath(.{ .cwd_relative = "lib" });

    // Add PortAudio
    exe.linkSystemLibrary("portaudio");
    exe.linkLibC();

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run Fado music player");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const exe_tests = b.addTest(.{
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
