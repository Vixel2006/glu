const std = @import("std");
const c = std.c;

/// Check if a process with the given PID is still alive.
///
/// Uses `access(F_OK)` on `/proc/<pid>/status`, which is a cheap
/// OS-level existence check with no privileges required.
pub fn is_alive(pid: u32) bool {
    var buf: [64]u8 = undefined;
    const path_len = (std.fmt.bufPrint(&buf, "/proc/{d}/status", .{pid}) catch return false).len;
    buf[path_len] = 0;
    return c.access(buf[0..path_len :0], 0) == 0;
}
