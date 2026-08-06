const std = @import("std");
const c = std.c;
const os = std.os.linux;

const Topic = @import("topic.zig").Topic;
const ShmScanner = @import("snapshot.zig").ShmScanner;
const is_alive = @import("../registry.zig").is_alive;

/// Scan `/dev/shm` for glu topics and unlink the stale ones.
///
/// Called on shutdown to clean up shared memory segments that were left
/// behind by a crash. Only segments whose owning process (`owner_pid`) is
/// dead or unknown are unlinked: a live owner's segment may belong to a
/// still-running glu node and must not be destroyed.
pub fn cleanup_topics() void {
    var scan = ShmScanner.init() catch return;
    defer scan.deinit();

    while (scan.next()) |name| blk: {
        var shm_name_buf: [256:0]u8 = undefined;
        const shm_name_len = (std.fmt.bufPrint(shm_name_buf[0..255], "/{s}", .{name}) catch continue).len;
        shm_name_buf[shm_name_len] = 0;

        var topic = Topic.open(shm_name_buf[0..shm_name_len :0]) catch break :blk;
        defer topic.close();

        const owner_pid: u32 = topic.header.owner_pid;
        if (owner_pid == 0 or !is_alive(owner_pid)) {
            _ = c.shm_unlink(shm_name_buf[0..shm_name_len :0]);
        }
    }
}

test "cleanup_topics removes only segments whose owner is dead" {
    const TestMsg = packed struct { x: u32 };
    const Channel = @import("../channel.zig").Channel;

    // A segment owned by a live process (this one) must survive cleanup.
    _ = c.shm_unlink("/glu_test_cleanup_live");
    var live = try Channel.open("/glu_test_cleanup_live", @sizeOf(TestMsg), 4, .reliable);
    defer live.close();

    // A segment left by a crashed owner (child exits without closing) must be removed.
    _ = c.shm_unlink("/glu_test_cleanup_dead");
    const pid = c.fork();
    if (pid == 0) {
        const dead = Channel.open("/glu_test_cleanup_dead", @sizeOf(TestMsg), 4, .reliable) catch c.exit(1);
        _ = dead;
        c.exit(0);
    }
    _ = c.waitpid(pid, null, 0);

    cleanup_topics();

    const rdonly: c_int = @as(c_int, @bitCast(os.O{ .ACCMODE = .RDONLY }));

    const fd_live = c.shm_open("/glu_test_cleanup_live", rdonly, 0);
    try std.testing.expect(fd_live != -1);
    if (fd_live != -1) _ = c.close(fd_live);

    const fd_dead = c.shm_open("/glu_test_cleanup_dead", rdonly, 0);
    try std.testing.expectEqual(@as(c_int, -1), fd_dead);
    if (fd_dead != -1) _ = c.close(fd_dead);
}
