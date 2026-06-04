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
    const zgpu = b.dependency("zgpu", .{});
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

    const release_step = b.step("release", "Build release binaries for all platforms");
    const release_targets = [_]struct { name: []const u8, query: std.Target.Query }{
        .{ .name = "x86_64-linux", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu } },
        .{ .name = "aarch64-macos", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
        .{ .name = "x86_64-macos", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
        // Windows currently does not work for cross compilation (some issue in deps)
        //.{ .name = "x86_64-windows", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
    };
    for (release_targets) |rt| {
        const release_target = b.resolveTargetQuery(rt.query);
        const release_zgpu = b.dependency("zgpu", .{ .target = release_target, .optimize = .ReleaseFast });
        const release_zclay = b.dependency("zclay", .{ .target = release_target, .optimize = .ReleaseFast });
        const release_zglfw = b.dependency("zglfw", .{ .target = release_target, .optimize = .ReleaseFast });
        const release_truetype = b.dependency("TrueType", .{});
        const release_lib_mod = b.createModule(.{
            .root_source_file = b.path("src/zclay_wgpu.zig"),
            .target = release_target,
            .optimize = .ReleaseFast,
        });
        release_lib_mod.addImport("zgpu", release_zgpu.module("root"));
        release_lib_mod.addImport("zclay", release_zclay.module("zclay"));
        release_lib_mod.addImport("zglfw", release_zglfw.module("root"));
        release_lib_mod.addImport("TrueType", release_truetype.module("TrueType"));
        release_lib_mod.linkLibrary(release_zglfw.artifact("glfw"));

        const release_exe = b.addExecutable(.{
            .name = "zclay_wgpu",
            .root_module = b.createModule(.{
                .root_source_file = b.path("example/main.zig"),
                .target = release_target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "zclay_wgpu", .module = release_lib_mod },
                },
            }),
        });

        release_exe.root_module.linkLibrary(release_zgpu.artifact("zdawn"));
        @import("zgpu").addLibraryPathsTo(release_exe);

        // zglfw/system_sdk paths do not propagate to the final link step.
        if (release_zglfw.builder.lazyDependency("system_sdk", .{})) |system_sdk| {
            switch (release_target.result.os.tag) {
                .linux => {
                    if (release_target.result.cpu.arch.isX86()) {
                        const lib_path = system_sdk.path("linux/lib/x86_64-linux-gnu");
                        release_lib_mod.addLibraryPath(lib_path);
                        release_exe.root_module.addLibraryPath(lib_path);
                    } else if (release_target.result.cpu.arch.isAARCH64()) {
                        const lib_path = system_sdk.path("linux/lib/aarch64-linux-gnu");
                        release_lib_mod.addLibraryPath(lib_path);
                        release_exe.root_module.addLibraryPath(lib_path);
                    }
                },
                .macos => {
                    release_exe.root_module.addFrameworkPath(system_sdk.path("macos12/System/Library/Frameworks"));
                    release_exe.root_module.addLibraryPath(system_sdk.path("macos12/usr/lib"));
                    release_exe.root_module.addSystemIncludePath(system_sdk.path("macos12/usr/include"));
                },
                else => {},
            }
        }

        const install = b.addInstallArtifact(release_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("release/{s}", .{rt.name}) } },
        });
        release_step.dependOn(&install.step);
    }
}
