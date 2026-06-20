const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cuda_path = b.option([]const u8, "CUDA_PATH", "CUDA installation path") orelse "/opt/cuda";

    const mod = b.addModule("glu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{cuda_path}) });

    const exe = b.addExecutable(.{
        .name = "glu",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "glu", .module = mod },
            },
        }),
    });

    const exe_mod = exe.root_module;
    exe_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{cuda_path}) });
    exe_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib64", .{cuda_path}) });
    exe_mod.linkSystemLibrary("cuda", .{});
    exe_mod.linkSystemLibrary("cudart", .{});
    exe_mod.linkSystemLibrary("nvrtc", .{});

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });
    test_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{cuda_path}) });

    const lib_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);

    // Benchmark targets
    const bench_opts = .{ .target = target, .optimize = .ReleaseFast };
    const zbench_module = b.dependency("zbench", bench_opts).module("zbench");

    const bench_exe = b.addExecutable(.{
        .name = "glu-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{
                .{ .name = "glu", .module = mod },
                .{ .name = "zbench", .module = zbench_module },
            },
        }),
    });

    const bench_exe_mod = bench_exe.root_module;
    bench_exe_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{cuda_path}) });

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);
}
