const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("glu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

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

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    // ── C shared + static library ──────────────────────────────────────────
    //
    // Produces libglu.so and libglu.a in zig-out/lib/, with a C header
    // installed to zig-out/include/glu/glu.h.
    //
    // Usage:
    //   zig build glu-lib          # build both shared + static
    //   zig build glu-shared       # build shared only
    //   zig build glu-static       # build static only
    //

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "glu", .module = mod },
        },
    });

    const glu_shared = b.addLibrary(.{
        .name = "glu",
        .root_module = lib_mod,
        .linkage = .dynamic,
    });

    const install_shared = b.addInstallArtifact(glu_shared, .{});
    const shared_step = b.step("glu-shared", "Build libglu.so");
    shared_step.dependOn(&install_shared.step);

    const glu_static = b.addLibrary(.{
        .name = "glu",
        .root_module = lib_mod,
        .linkage = .static,
    });

    const install_static = b.addInstallArtifact(glu_static, .{});
    const static_step = b.step("glu-static", "Build libglu.a");
    static_step.dependOn(&install_static.step);

    const install_header = b.addInstallFile(b.path("include/glu/glu.h"), "include/glu/glu.h");
    const install_hpp = b.addInstallFile(b.path("include/glu/glu.hpp"), "include/glu/glu.hpp");

    const glu_lib_step = b.step("glu-lib", "Build libglu.so + libglu.a + headers");
    glu_lib_step.dependOn(&install_shared.step);
    glu_lib_step.dependOn(&install_static.step);
    glu_lib_step.dependOn(&install_header.step);
    glu_lib_step.dependOn(&install_hpp.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });

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

    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Adding LLDB for debugging
    const lldb = b.addSystemCommand(&.{
        "lldb",
        "--",
    });

    lldb.addArtifactArg(lib_tests);

    const lldb_step = b.step("debug", "Run the tests under lldb debugger");
    lldb_step.dependOn(&lldb.step);

    // ── Example executables ──────────────────────────────────────────────────
    //
    // Helper to build a single example executable and install it.
    // All examples import the `glu` module and link libc.
    //
    // Usage:
    //   const examples_step = b.step("examples", "Build all example executables");
    //   addExample(b, target, optimize, mod, examples_step,
    //              "glu-canonical-sensor", "examples/canonical/sensor.zig");

    const examples_step = b.step("examples", "Build all example executables");

    // -- canonical temperature monitoring ------------------------------------
    addExample(b, target, optimize, mod, examples_step,
        "glu-canonical-sensor", "examples/canonical/sensor.zig");
    addExample(b, target, optimize, mod, examples_step,
        "glu-canonical-processor", "examples/canonical/processor.zig");
    addExample(b, target, optimize, mod, examples_step,
        "glu-canonical-dashboard", "examples/canonical/dashboard.zig");
}

/// Build and install a single example executable.
///
/// Parameters:
///   name     — output binary name (e.g. "glu-telemetry-sensor")
///   src_path — path to the root .zig source file relative to the repo root
///
/// The resulting binary is installed to zig-out/bin/<name> and added as a
/// dependency of `examples_step` so `zig build examples` builds all of them.
fn addExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glu_mod: *std.Build.Module,
    examples_step: *std.Build.Step,
    name: []const u8,
    src_path: []const u8,
) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(src_path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "glu", .module = glu_mod },
            },
        }),
    });
    const install = b.addInstallArtifact(exe, .{});
    examples_step.dependOn(&install.step);
}
