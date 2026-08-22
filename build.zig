const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("glu", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{},
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
        .use_llvm = true,
        .use_lld = true,
    });

    b.installArtifact(exe);

    // C ABI shared library (libglu.so)
    const lib = b.addLibrary(.{
        .name = "glu",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{},
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    b.installArtifact(lib);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{},
    });

    const lib_tests = b.addTest(.{
        .root_module = test_mod,
        .use_llvm = true,
        .use_lld = true,
    });

    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);

    // Adding LLDB for debugging
    const lldb = b.addSystemCommand(&.{
        "lldb",
        "--",
    });

    lldb.addArtifactArg(lib_tests);

    const lldb_step = b.step("debug", "Run the tests under lldb debugger");
    lldb_step.dependOn(&lldb.step);
}
