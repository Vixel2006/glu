const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const os = std.os.linux;

const Registry = @import("../registry.zig");
const constants = @import("../constants.zig");

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
    if (!Registry.valid_name(name)) return error.InvalidName;

    var args_buf: [constants.MAX_ARGV][]const u8 = undefined;
    var data_buf: [constants.MAX_ARGV_LEN]u8 = undefined;
    const argc = try Registry.read_argv(&args_buf, &data_buf, name);
    if (argc == 0) return false;

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, logs_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return ProcessErr.FileSystem,
    };

    var path_buf: [256]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.log", .{ logs_dir, name });
    var file: std.Io.File = cwd.createFile(io, log_path, .{
        .truncate = true,
        .permissions = .fromMode(0o600),
    }) catch return error.FileSystem;
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
