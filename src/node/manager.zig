const std = @import("std");
const c = std.c;
const os = std.os.linux;

const Registry = @import("../registry.zig");

/// Stop all registered nodes by sending SIGTERM to each alive process
/// and unregistering it from the node registry.
///
/// Returns the number of nodes that were signalled.
pub fn stopAllNodes(allocator: std.mem.Allocator) !usize {
    const entries = try Registry.listAlive(allocator);
    defer {
        for (entries) |e| allocator.free(e.name);
        allocator.free(entries);
    }

    var stopped: usize = 0;
    for (entries) |e| {
        if (e.alive) {
            _ = c.kill(@as(i32, @intCast(e.pid)), os.SIG.TERM);
            stopped += 1;
        }
        Registry.unregister(e.name);
    }

    return stopped;
}
