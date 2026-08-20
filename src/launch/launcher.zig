const std = @import("std");
const assert = std.debug.assert;
const NodeConfig = @import("toml.zig").NodeConfig;
const MAX_ARGS = @import("../constants.zig").MAX_ARGS;
const Registry = @import("../registry.zig");

const LaunchErr = error{
    FileSystem,
};

/// A process spawned by the launcher.
pub const LaunchedNode = struct {
    name: []const u8,
    child: std.process.Child,
};

/// Build the argv vector for `cfg` into `out`, returning the filled slice.
fn build_argv(cfg: *const NodeConfig, out: [][]const u8) []const []const u8 {
    if (cfg.bin.len > 0) {
        assert(1 + cfg.extra_cfg_len <= out.len);
        out[0] = cfg.bin;
        for (cfg.extra_cfg[0..cfg.extra_cfg_len], 0..) |arg, i| out[1 + i] = arg;
        return out[0 .. 1 + cfg.extra_cfg_len];
    }
    assert(4 + cfg.extra_cfg_len <= out.len);
    out[0] = "zig";
    out[1] = "run";
    out[2] = cfg.path;
    out[3] = "--";
    for (cfg.extra_cfg[0..cfg.extra_cfg_len], 0..) |arg, i| out[4 + i] = arg;
    return out[0 .. 4 + cfg.extra_cfg_len];
}

/// Launch nodes as foreground processes with stdin/stdout/stderr inherited.
///
/// Writes each handle into `children` and returns the number launched. On
/// error, all children launched so far are killed.
pub fn launch(io: std.Io, cfgs: []const NodeConfig, children: []LaunchedNode) LaunchErr!usize {
    var launched: usize = 0;
    for (cfgs) |*cfg| {
        var argv_buf: [4 + MAX_ARGS][]const u8 = undefined;
        const argv = build_argv(cfg, argv_buf[0..]);

        const child = std.process.spawn(io, .{
            .argv = argv,
            .stdout = .inherit,
            .stdin = .inherit,
            .stderr = .inherit,
        }) catch {
            for (children[0..launched]) |*n| n.child.kill(io);
            return LaunchErr.FileSystem;
        };

        Registry.register_argv(cfg.name, argv) catch |err| {
            std.log.warn("failed to persist argv for node '{s}': {}", .{ cfg.name, err });
        };
        if (child.id) |pid| {
            Registry.register_pid(cfg.name, @intCast(pid)) catch |err| {
                std.log.warn("failed to register pid {} for node '{s}': {}", .{ pid, cfg.name, err });
            };
        }
        children[launched] = .{ .name = cfg.name, .child = child };
        launched += 1;
    }
    return launched;
}

/// Launch nodes as detached background processes, logging to `logs_dir`.
///
/// Each node's stdout/stderr is redirected to `logs_dir/<name>.log` and its
/// PID is registered for lifecycle management.
pub fn launch_detached(io: std.Io, cfgs: []const NodeConfig, logs_dir: []const u8) LaunchErr!void {
    assert(logs_dir.len > 0);
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, logs_dir) catch return LaunchErr.FileSystem;

    for (cfgs) |*cfg| blk: {
        if (!Registry.valid_name(cfg.name)) {
            std.log.err("launch_detached: node name '{s}' is not a valid identifier", .{cfg.name});
            break :blk;
        }

        var argv_buf: [4 + MAX_ARGS][]const u8 = undefined;
        const argv = build_argv(cfg, argv_buf[0..]);

        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.log", .{ logs_dir, cfg.name }) catch break :blk;

        var file: std.Io.File = cwd.createFile(io, path, .{
            .truncate = true,
            .permissions = .fromMode(0o600),
        }) catch return LaunchErr.FileSystem;
        defer file.close(io);

        const child = std.process.spawn(io, .{
            .argv = argv,
            .stdout = .{ .file = file },
            .stdin = .ignore,
            .stderr = .{ .file = file },
        }) catch |err| {
            var fw = std.Io.File.stderr().writerStreaming(io, &.{});
            fw.interface.print("error spawning '{s}': {s}\n", .{ cfg.name, @errorName(err) }) catch {};
            break :blk;
        };

        Registry.register_argv(cfg.name, argv) catch |err| {
            std.log.warn("failed to persist argv for node '{s}': {}", .{ cfg.name, err });
        };
        if (child.id) |pid| {
            Registry.register_pid(cfg.name, @intCast(pid)) catch |err| {
                std.log.warn("failed to register pid {} for node '{s}': {}", .{ pid, cfg.name, err });
            };
        }
    }
}

test "launch and wait" {
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(io, .{ .sub_path = "ok.zig", .data = "pub fn main() u8 { return 0; }" });

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/ok.zig", .{&dir.sub_path});

    const cfgs = [_]NodeConfig{.{ .name = "ok", .path = path }};
    var children: [1]LaunchedNode = undefined;
    const n = try launch(io, &cfgs, &children);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("ok", children[0].name);
    const term = try children[0].child.wait(io);
    try std.testing.expectEqual(term, std.process.Child.Term{ .exited = 0 });
}

test "launch with extra arguments" {
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

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/args.zig", .{&dir.sub_path});

    var cfg = NodeConfig{ .name = "args_test", .path = path };
    cfg.extra_cfg[0] = "--fps";
    cfg.extra_cfg[1] = "30";
    cfg.extra_cfg_len = 2;
    const cfgs = [_]NodeConfig{cfg};

    var children: [1]LaunchedNode = undefined;
    const n = try launch(io, &cfgs, &children);
    try std.testing.expectEqual(@as(usize, 1), n);

    const term = try children[0].child.wait(io);
    try std.testing.expectEqual(term, std.process.Child.Term{ .exited = 0 });
}

test "launch_detached: creates log directory" {
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    var logs_buf: [256]u8 = undefined;
    const logs_dir = try std.fmt.bufPrint(&logs_buf, ".zig-cache/tmp/{s}/logs_test", .{&dir.sub_path});

    try launch_detached(io, &.{}, logs_dir);

    const cwd = std.Io.Dir.cwd();
    var opened = try cwd.openDir(io, logs_dir, .{ .iterate = true });
    opened.close(io);
}

test "launch_detached: creates log file with process output" {
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    var logs_buf: [256]u8 = undefined;
    const logs_dir = try std.fmt.bufPrint(&logs_buf, ".zig-cache/tmp/{s}/logs_output", .{&dir.sub_path});

    var cfgs = [_]NodeConfig{.{ .name = "echo_node", .bin = "/bin/echo" }};
    const launch_cfgs = [_]NodeConfig{cfg: {
        cfgs[0].extra_cfg[0] = "hello from detached";
        cfgs[0].extra_cfg_len = 1;
        break :cfg cfgs[0];
    }};

    try launch_detached(io, &launch_cfgs, logs_dir);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    const cwd = std.Io.Dir.cwd();
    var path_buf: [256]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&path_buf, "{s}/echo_node.log", .{logs_dir});

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
