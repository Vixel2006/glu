const std = @import("std");
const NodeConfig = @import("toml.zig").NodeConfig;
const Registry = @import("../registry.zig");

const LaunchErr = error{
    OutOfMemory,
    FileSystem,
    NoSpaceLeft,
};

/// A process that was spawned by the launcher.
pub const LaunchedNode = struct {
    name: []const u8,
    child: std.process.Child,
};

fn buildArgv(allocator: std.mem.Allocator, cfg: *const NodeConfig) LaunchErr![]const []const u8 {
    if (cfg.bin.len > 0) {
        const args = try allocator.alloc([]const u8, 1 + cfg.extra_cfg.len);
        args[0] = cfg.bin;
        for (cfg.extra_cfg, 0..) |arg, i| args[1 + i] = arg;
        return args;
    }

    const args = try allocator.alloc([]const u8, 4 + cfg.extra_cfg.len);
    args[0] = "zig";
    args[1] = "run";
    args[2] = cfg.path;
    args[3] = "--";
    for (cfg.extra_cfg, 0..) |arg, i| args[4 + i] = arg;
    return args;
}

/// Launch nodes as foreground processes.
///
/// Each node is spawned with stdin/stdout/stderr inherited.
/// Returns an owned slice of handles that the caller can wait on.
/// On error, all previously-launched children are killed.
pub fn launch(io: std.Io, allocator: std.mem.Allocator, cfgs: []const NodeConfig) LaunchErr![]LaunchedNode {
    var launched = try std.ArrayListAligned(LaunchedNode, null).initCapacity(allocator, cfgs.len);
    errdefer {
        for (launched.items) |*n| n.child.kill(io);
        launched.deinit(allocator);
    }

    for (cfgs) |cfg| {
        const argv = try buildArgv(allocator, &cfg);
        const child = std.process.spawn(io, .{
            .argv = argv,
            .stdout = .inherit,
            .stdin = .inherit,
            .stderr = .inherit,
        }) catch return LaunchErr.FileSystem;
        allocator.free(argv);
        launched.appendAssumeCapacity(.{ .name = cfg.name, .child = child });
    }

    return launched.toOwnedSlice(allocator);
}

/// Launch nodes as detached background processes.
///
/// Each node's stdout/stderr is redirected to a log file in `logs_dir`.
/// Nodes are registered in the registry for lifecycle management.
pub fn launchDetached(io: std.Io, allocator: std.mem.Allocator, cfgs: []const NodeConfig, logs_dir: []const u8) LaunchErr!void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, logs_dir) catch return LaunchErr.FileSystem;

    for (cfgs) |cfg| {
        const argv = buildArgv(allocator, &cfg) catch continue;

        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.log", .{ logs_dir, cfg.name });

        const file = cwd.createFile(io, path, .{ .read = true }) catch return LaunchErr.FileSystem;
        defer file.close(io);

        const child = std.process.spawn(io, .{
            .argv = argv,
            .stdout = .{ .file = file },
            .stdin = .ignore,
            .stderr = .{ .file = file },
        }) catch |err| {
            allocator.free(argv);
            var fw = std.Io.File.stderr().writerStreaming(io, &.{});
            fw.interface.print("error spawning '{s}': {s}\n", .{ cfg.name, @errorName(err) }) catch {};
            continue;
        };
        allocator.free(argv);
        if (child.id) |pid| Registry.registerPid(cfg.name, @intCast(pid)) catch {};
    }
}

fn testNodePath(allocator: std.mem.Allocator, dir: std.testing.TmpDir, name: []const u8) LaunchErr![]const u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ &dir.sub_path, name });
}

test "launch and wait" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(io, .{ .sub_path = "ok.zig", .data = "pub fn main() u8 { return 0; }" });
    const path = try testNodePath(allocator, dir, "ok.zig");
    defer allocator.free(path);

    const cfgs = &[_]NodeConfig{.{ .name = "ok", .path = path }};
    const launched = try launch(io, allocator, cfgs);
    defer {
        for (launched) |*n| n.child.kill(io);
        allocator.free(launched);
    }

    try std.testing.expectEqual(@as(usize, 1), launched.len);
    try std.testing.expectEqualStrings("ok", launched[0].name);
    const term = try launched[0].child.wait(io);
    try std.testing.expectEqual(term, std.process.Child.Term{ .exited = 0 });
}

test "launch with extra arguments" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const node_src =
        \\const std = @import("std");
        \\pub fn main(init: std.process.Init.Minimal) !void {
        \\    var iter = std.process.Args.Iterator.init(init.args);
        \\    _ = iter.next();
        \\    const first = iter.next() orelse std.process.exit(1);
        \\    const second = iter.next() orelse std.process.exit(2);
        \\    if (std.mem.eql(u8, first, "--fps") and std.mem.eql(u8, second, "30"))
        \\        std.process.exit(0)
        \\    else
        \\        std.process.exit(3);
        \\}
    ;
    try dir.dir.writeFile(io, .{ .sub_path = "args.zig", .data = node_src });
    const path = try testNodePath(allocator, dir, "args.zig");
    defer allocator.free(path);

    const extra = &[_][]const u8{ "--fps", "30" };
    const cfgs = &[_]NodeConfig{.{ .name = "args_test", .path = path, .extra_cfg = extra }};
    const launched = try launch(io, allocator, cfgs);
    defer {
        for (launched) |*n| n.child.kill(io);
        allocator.free(launched);
    }

    const term = try launched[0].child.wait(io);
    try std.testing.expectEqual(term, std.process.Child.Term{ .exited = 0 });
}

test "launchDetached: creates log directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const logs_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/logs_test", .{&dir.sub_path});
    defer allocator.free(logs_dir);

    try launchDetached(io, allocator, &.{}, logs_dir);

    const cwd = std.Io.Dir.cwd();
    var opened = try cwd.openDir(io, logs_dir, .{ .iterate = true });
    opened.close(io);
}

test "launchDetached: creates log file with process output" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    const logs_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/logs_output", .{&dir.sub_path});
    defer allocator.free(logs_dir);

    const cfgs = &[_]NodeConfig{
        .{ .name = "echo_node", .bin = "/bin/echo", .extra_cfg = &.{"hello from detached"} },
    };

    try launchDetached(io, allocator, cfgs, logs_dir);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    const cwd = std.Io.Dir.cwd();
    var path_buf: [256]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.log", .{ logs_dir, "echo_node" });

    var file = try cwd.openFile(io, log_path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    var ri = &reader.interface;
    var read_buf: [4096]u8 = undefined;
    const n = try ri.readSliceShort(&read_buf);

    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, read_buf[0..n], "hello from detached") != null);
}
