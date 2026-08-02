const std = @import("std");
const c = std.c;
const os = std.os.linux;

const Registry = @import("../registry.zig");

/// Stop all registered nodes by sending SIGTERM to each alive process
/// and unregistering it from the node registry.
///
/// Returns the number of nodes that were signalled.
pub fn stop_all_nodes() !usize {
    var entry_buf: [128]Registry.NodeEntry = undefined;
    const count = try Registry.list_alive(&entry_buf);

    var stopped: usize = 0;
    for (entry_buf[0..count]) |e| {
        if (e.alive) {
            _ = c.kill(@as(i32, @intCast(e.pid)), os.SIG.TERM);
            stopped += 1;
        }
        Registry.unregister(e.name[0..e.name_len]);
    }

    return stopped;
}
