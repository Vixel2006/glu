const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const os = std.os.linux;

const Registry = @import("../registry.zig");

const ProcessErr = error{
    OutOfMemory,
    FileSystem,
    NoSpaceLeft,
    ProcessSpawnFailed,
};

/// Stop a single named node by PID.
///
/// Reads the registered PID, sends SIGTERM, waits briefly for it to exit,
/// escalates to SIGKILL if it lingers, then unregisters it.
/// Returns `true` if a process was signalled, `false` if it wasn't running.
pub fn stop_node(io: std.Io, name: []const u8) !bool {
    const pid = try Registry.get_pid(name) orelse {
        Registry.unregister(name);
        return false;
    };

    if (!Registry.is_alive(pid)) {
        Registry.unregister(name);
        return false;
    }

    if (c.kill(@as(i32, @intCast(pid)), os.SIG.TERM) != 0) return false;

    // Poll `/proc/<pid>` until it exits; escalate to SIGKILL if it lingers.
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (!Registry.is_alive(pid)) break;
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
    }
    if (Registry.is_alive(pid)) {
        _ = c.kill(@as(i32, @intCast(pid)), os.SIG.KILL);
    }

    Registry.unregister(name);
    return true;
}

/// Start a node by re-spawning its persisted argv manifest.
///
/// Launches detached (stdout/stderr to `logs_dir/<name>.log`) and re-registers
/// its PID. Returns `true` if spawned, `false` if no manifest exists.
pub fn start_node(io: std.Io, name: []const u8, logs_dir: []const u8) !bool {
    assert(logs_dir.len > 0);

    var args_buf: [Registry.MAX_ARGV][]const u8 = undefined;
    var data_buf: [Registry.MAX_ARGV_LEN]u8 = undefined;
    const argc = try Registry.read_argv(&args_buf, &data_buf, name);
    if (argc == 0) return false;

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, logs_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return ProcessErr.FileSystem,
    };

    var path_buf: [256]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.log", .{ logs_dir, name });
    const file = cwd.createFile(io, log_path, .{ .read = true }) catch return ProcessErr.FileSystem;
    defer file.close(io);

    const child = std.process.spawn(io, .{
        .argv = args_buf[0..argc],
        .stdout = .{ .file = file },
        .stdin = .ignore,
        .stderr = .{ .file = file },
    }) catch return ProcessErr.ProcessSpawnFailed;

    if (child.id) |pid| {
        Registry.register_pid(name, @intCast(pid)) catch |err| {
            std.log.warn("failed to register pid {} for node '{s}': {}", .{ pid, name, err });
        };
    }
    return true;
}

/// Restart a node: stop it (if running), then re-spawn from its manifest.
///
/// Returns `false` if the node has no persisted manifest to re-spawn from.
pub fn restart_node(io: std.Io, name: []const u8, logs_dir: []const u8) !bool {
    _ = try stop_node(io, name);
    return try start_node(io, name, logs_dir);
}

/// Stop every registered node.
///
/// Reuses `stop_node` per entry so it stays consistent with selective stops.
pub fn stop_all_nodes(io: std.Io) !usize {
    var entry_buf: [128]Registry.NodeEntry = undefined;
    const count = try Registry.list_alive(&entry_buf);

    var stopped: usize = 0;
    for (entry_buf[0..count]) |e| {
        if (try stop_node(io, e.name[0..e.name_len])) stopped += 1;
    }
    return stopped;
}
