const std = @import("std");
const os = std.os.linux;
const c = std.c;

const DaemonState = @import("state.zig").DaemonState;
const is_alive = @import("../utils/process.zig").is_alive;
const protocol = @import("protocol.zig");
const constants = @import("../constants.zig");

pub fn spawn_node(
    io: std.Io,
    state: *DaemonState,
    name: []const u8,
    argv: []const []const u8,
    logs_dir: []const u8,
) !u32 {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, logs_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.FileSystem,
    };

    var path_buf: [256]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.log", .{ logs_dir, name });
    var file = try cwd.createFile(io, log_path, .{
        .truncate = true,
        .permissions = .fromMode(0o600),
    });
    defer file.close(io);

    const child = std.process.spawn(io, .{
        .argv = argv,
        .stdout = .{ .file = file },
        .stdin = .ignore,
        .stderr = .{ .file = file },
    }) catch return error.ProcessSpawnFailed;

    const pid: u32 = @intCast(child.id orelse return error.ProcessSpawnFailed);

    // Pack argv into nul-separated buffer for state storage
    var argv_buf: [constants.MAX_ARGV_LEN]u8 = undefined;
    var len: usize = 0;
    for (argv) |arg| {
        if (len + arg.len + 1 > argv_buf.len) break;
        @memcpy(argv_buf[len .. len + arg.len], arg);
        len += arg.len;
        argv_buf[len] = 0;
        len += 1;
    }

    const node = try state.add_or_update_node(name, pid, argv_buf[0..len]);
    node.child_handle = child;
    return pid;
}

// TODO: I think here a much better way to make this, is instead of the signal terminal
// we can actually send a signal to the node and the node will have running = false when we signal
pub fn stop_node(io: std.Io, state: *DaemonState, name: []const u8) !bool {
    const node = state.find_node_by_name(name) orelse return false;
    if (node.status != .running or node.pid == 0) return false;

    const pid = node.pid;
    if (c.kill(@as(i32, @intCast(pid)), os.SIG.TERM) == 0) {
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            if (!is_alive(pid)) break;
            try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake);
        }
        if (is_alive(pid)) {
            _ = c.kill(@as(i32, @intCast(pid)), os.SIG.KILL);
        }
    }

    node.status = .stopped;
    return true;
}

pub fn stop_all(io: std.Io, state: *DaemonState) void {
    _ = io;
    for (state.nodes[0..state.node_count]) |*n| {
        if (n.status == .running and n.pid > 0) {
            _ = c.kill(@as(i32, @intCast(n.pid)), os.SIG.TERM);
            n.status = .stopped;
        }
    }
}
