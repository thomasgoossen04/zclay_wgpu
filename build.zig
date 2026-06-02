const std = @import("std");

// So that users can do
// const zclay_wgpu = b.dependency("zclay_wgpu", .{});
// @import("zclay_wgpu").addTo(exe);
// (same as the example exe)
pub fn addTo(compile_step: *std.Build.Step.Compile) void {
    const b = compile_step.step.owner;
    const dep = b.dependencyFromBuildZig(@This(), .{
        .target = compile_step.root_module.resolved_target orelse b.host,
        .optimize = compile_step.root_module.optimize orelse .Debug,
    });
    compile_step.root_module.addImport("zclay_wgpu", dep.module("zclay_wgpu"));
    const zgpu_dep = dep.builder.dependency("zgpu", .{
        .target = compile_step.root_module.resolved_target orelse dep.builder.host,
        .optimize = compile_step.root_module.optimize orelse .Debug,
    });
    compile_step.root_module.linkLibrary(zgpu_dep.artifact("zdawn"));
    @import("zgpu").addLibraryPathsTo(compile_step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("zclay_wgpu", .{
        .root_source_file = b.path("src/zclay_wgpu.zig"),
        .target = target,
    });

    // Deps
    const zgpu = b.dependency("zgpu", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("zgpu", zgpu.module("root"));
    const zclay = b.dependency("zclay", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("zclay", zclay.module("zclay"));
    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("zglfw", zglfw.module("root"));
    const truetype = b.dependency("TrueType", .{});
    mod.addImport("TrueType", truetype.module("TrueType"));

    if (target.result.os.tag != .emscripten) {
        mod.linkLibrary(zglfw.artifact("glfw"));
    }

    const exe = b.addExecutable(.{
        .name = "zclay_wgpu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zclay_wgpu", .module = mod },
            },
        }),
    });

    exe.root_module.linkLibrary(zgpu.artifact("zdawn"));
    @import("zgpu").addLibraryPathsTo(exe);
    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
