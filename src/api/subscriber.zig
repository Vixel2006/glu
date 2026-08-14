const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const Channel = @import("../channel.zig").Channel;
const MAX_READERS = @import("../channel.zig").MAX_READERS;
const chan_peek = @import("../channel.zig").peek;
const chan_ack = @import("../channel.zig").ack;
const write = @import("../channel.zig").write;

const SubErr = error{
    OutOfMemory,
    ShmOpenFailed,
    MmapFailed,
    InvalidSegment,
    NoReaderSlots,
};

/// High-level subscriber wrapping a raw `Channel`.
///
/// Each subscriber occupies one slot in the channel's reader array
/// (0 .. MAX_READERS-1). Multiple subscribers can attach to the
/// same topic independently.
pub const Subscriber = struct {
    channel: Channel,
    id: u32,

    /// Create a new subscriber for topic `name`.
    ///
    /// The reader slot is claimed atomically (compare-and-swap on the
    /// whole reader entry), so concurrent `init` calls across processes
    /// never grab the same slot. The claim writes the owning PID and the
    /// initial cursor (set to the current write position so a
    /// late-joining subscriber only sees new messages) in a single atomic
    /// step, so `sweep_dead_readers` can never clear a freshly claimed
    /// slot based on a stale PID.
    pub fn init(name: []const u8, msg_size: u32, capacity: u32) SubErr!Subscriber {
        var chan = try Channel.open(name, msg_size, capacity, .reliable);

        const pid: u32 = @intCast(std.os.linux.getpid());
        _ = @cmpxchgStrong(u32, &chan.header.owner_pid, pid, 0, .acq_rel, .acquire);

        const current_write = @atomicLoad(u32, &chan.header.write, .acquire);

        var claimed: bool = false;
        var id: u32 = undefined;
        for (0..MAX_READERS) |i| {
            const slot: u32 = @intCast(i);
            const entry = (@as(u64, pid) << 32) | current_write;
            const existing = @cmpxchgWeak(u64, &chan.header.readers[slot], 0, entry, .acq_rel, .acquire);
            if (existing == null) {
                claimed = true;
                id = slot;
                break;
            }
        }

        if (!claimed) {
            chan.close();
            return error.NoReaderSlots;
        }

        return .{ .id = id, .channel = chan };
    }

    /// Close this subscriber and mark its reader slot as inactive.
    ///
    /// Clearing the reader entry to zero removes it from the
    /// slowest-reader calculation so the publisher won't wait for us.
    pub fn deinit(self: *Subscriber) void {
        assert(self.id < MAX_READERS);
        @atomicStore(u64, &self.channel.header.readers[self.id], 0, .release);
        self.channel.close();
    }

    /// Return the next unread message without consuming it.
    ///
    /// The returned pointer stays valid until `ack` is called. Copy the
    /// message before acknowledging, otherwise the publisher may wrap
    /// around and overwrite the slot.
    pub fn peek(self: *Subscriber) ?*anyopaque {
        assert(self.id < MAX_READERS);
        const entry = @atomicLoad(u64, &self.channel.header.readers[self.id], .acquire);
        const r: u32 = @truncate(entry);
        const w = @atomicLoad(u32, &self.channel.header.write, .acquire);
        if (r < w) return chan_peek(&self.channel, self.id);
        return null;
    }

    /// Mark the most recently peeked message as consumed.
    pub fn ack(self: *Subscriber) void {
        assert(self.id < MAX_READERS);
        chan_ack(&self.channel, self.id);
    }
};

test "Subscriber: publish via raw Channel, peek and ack" {
    const TestMsg = packed struct { x: u32, y: u32 };

    // we do unlink to close the stale POSIX shared memory from prior failed tests if any
    _ = c.shm_unlink("/glu_test_subscriber");

    var sub = try Subscriber.init("/glu_test_subscriber", @sizeOf(TestMsg), 2);
    defer sub.deinit();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open("/glu_test_subscriber", @sizeOf(TestMsg), 2, .reliable) catch c.exit(1);
        write(&child_chan, @ptrCast(&TestMsg{ .x = 99, .y = 42 }));
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    const raw = sub.peek() orelse return error.TestFailed;
    const msg_ptr: *const TestMsg = @ptrCast(@alignCast(raw));
    try std.testing.expect(msg_ptr.x == 99);
    try std.testing.expect(msg_ptr.y == 42);
    sub.ack();
    _ = c.waitpid(pid, null, 0);
}

test "two subscribers on the same channel both receive messages" {
    const TestMsg = packed struct { x: u32, y: u32 };

    _ = c.shm_unlink("/glu_test_two_subs");

    var sub0 = try Subscriber.init("/glu_test_two_subs", @sizeOf(TestMsg), 8);
    defer sub0.deinit();
    var sub1 = try Subscriber.init("/glu_test_two_subs", @sizeOf(TestMsg), 8);
    defer sub1.deinit();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open("/glu_test_two_subs", @sizeOf(TestMsg), 8, .reliable) catch c.exit(1);
        write(&child_chan, @ptrCast(&TestMsg{ .x = 1, .y = 2 }));
        write(&child_chan, @ptrCast(&TestMsg{ .x = 3, .y = 4 }));
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }

    {
        const m0a = sub0.peek() orelse return error.TestFailed;
        const p0a: *const TestMsg = @ptrCast(@alignCast(m0a));
        try std.testing.expect(p0a.x == 1);
        try std.testing.expect(p0a.y == 2);
        sub0.ack();
    }
    {
        const m0b = sub0.peek() orelse return error.TestFailed;
        const p0b: *const TestMsg = @ptrCast(@alignCast(m0b));
        try std.testing.expect(p0b.x == 3);
        try std.testing.expect(p0b.y == 4);
        sub0.ack();
    }
    {
        const m1a = sub1.peek() orelse return error.TestFailed;
        const p1a: *const TestMsg = @ptrCast(@alignCast(m1a));
        try std.testing.expect(p1a.x == 1);
        try std.testing.expect(p1a.y == 2);
        sub1.ack();
    }
    {
        const m1b = sub1.peek() orelse return error.TestFailed;
        const p1b: *const TestMsg = @ptrCast(@alignCast(m1b));
        try std.testing.expect(p1b.x == 3);
        try std.testing.expect(p1b.y == 4);
        sub1.ack();
    }

    _ = c.waitpid(pid, null, 0);
}

test "peek does not advance the read cursor" {
    const TestMsg = packed struct { x: u32, y: u32 };

    _ = c.shm_unlink("/glu_test_peek_noack");

    var sub = try Subscriber.init("/glu_test_peek_noack", @sizeOf(TestMsg), 4);
    defer sub.deinit();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open("/glu_test_peek_noack", @sizeOf(TestMsg), 4, .reliable) catch c.exit(1);
        write(&child_chan, @ptrCast(&TestMsg{ .x = 5, .y = 6 }));
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }

    const first = sub.peek() orelse return error.TestFailed;
    const second = sub.peek() orelse return error.TestFailed;
    try std.testing.expect(first == second);

    const p: *const TestMsg = @ptrCast(@alignCast(first));
    try std.testing.expect(p.x == 5);

    _ = c.waitpid(pid, null, 0);
}

test "subscriber slots are exhausted after MAX_READERS" {
    const TestMsg = packed struct { x: u32 };

    _ = c.shm_unlink("/glu_test_slot_exhaust");

    var subs: [MAX_READERS]Subscriber = undefined;
    for (&subs) |*s| {
        s.* = try Subscriber.init("/glu_test_slot_exhaust", @sizeOf(TestMsg), 8);
    }
    defer {
        for (&subs) |*s| s.deinit();
    }

    try std.testing.expectError(error.NoReaderSlots, Subscriber.init("/glu_test_slot_exhaust", @sizeOf(TestMsg), 8));
}

test "deinit frees a slot for reuse" {
    const TestMsg = packed struct { x: u32 };

    _ = c.shm_unlink("/glu_test_slot_reuse");

    {
        var sub = try Subscriber.init("/glu_test_slot_reuse", @sizeOf(TestMsg), 4);
        defer sub.deinit();
        try std.testing.expectEqual(@as(u32, 0), sub.id);
    }

    var sub2 = try Subscriber.init("/glu_test_slot_reuse", @sizeOf(TestMsg), 4);
    defer sub2.deinit();
    try std.testing.expectEqual(@as(u32, 0), sub2.id);
}

test "claim packs PID and cursor atomically" {
    const TestMsg = packed struct { x: u32 };

    _ = c.shm_unlink("/glu_test_atomic_claim");

    var sub = try Subscriber.init("/glu_test_atomic_claim", @sizeOf(TestMsg), 4);
    defer sub.deinit();

    const pid: u32 = @intCast(std.os.linux.getpid());
    const w = @atomicLoad(u32, &sub.channel.header.write, .acquire);
    const entry = @atomicLoad(u64, &sub.channel.header.readers[sub.id], .acquire);
    try std.testing.expectEqual((@as(u64, pid) << 32) | w, entry);
}

test "concurrent subscriber claims get unique slots and survive sweeps" {
    const TestMsg = packed struct { x: u32 };

    _ = c.shm_unlink("/glu_test_concurrent_claim");

    var chan = try Channel.open("/glu_test_concurrent_claim", @sizeOf(TestMsg), 8, .reliable);
    defer chan.close();

    const N = 8;
    var children: [N]std.c.pid_t = undefined;
    for (&children) |*child| {
        const pid = c.fork();
        if (pid == 0) {
            var sub = Subscriber.init("/glu_test_concurrent_claim", @sizeOf(TestMsg), 8) catch c.exit(10);
            const my_pid: u32 = @intCast(std.os.linux.getpid());
            // Hold the slot for a while so the parent can hammer sweeps.
            // If a sweep ever wiped our claim, the entry would read zero and
            // we bail out — this is exactly the race the atomic claim fixes.
            var i: usize = 0;
            while (i < 100) : (i += 1) {
                const entry = @atomicLoad(u64, &sub.channel.header.readers[sub.id], .acquire);
                if (entry == 0 or @as(u32, @intCast(entry >> 32)) != my_pid) c.exit(11);
                var ts = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
                _ = c.nanosleep(&ts, null);
            }
            // Leave the slot claimed so the parent can verify it below.
            c.exit(0);
        }
        child.* = pid;
    }

    // Hammer sweeps while the children hold their claims.
    var j: usize = 0;
    while (j < 500) : (j += 1) {
        @import("../channel.zig").sweep_dead_readers(&chan.header.readers);
    }

    for (children) |pid| {
        var status: c_int = 0;
        _ = c.waitpid(pid, &status, 0);
        const code = (status >> 8) & 0xff;
        try std.testing.expectEqual(@as(c_int, 0), code);
    }

    // Every slot is claimed, each by a distinct (now exited) subscriber PID.
    var live_count: usize = 0;
    for (&chan.header.readers) |*entry| {
        const entry_val = @atomicLoad(u64, entry, .acquire);
        if (entry_val != 0) {
            live_count += 1;
            const reader_pid: u32 = @intCast(entry_val >> 32);
            try std.testing.expect(reader_pid != 0);
        }
    }
    try std.testing.expectEqual(@as(usize, N), live_count);

    // The slots are distinct: every non-zero high-32 PID differs.
    for (0..MAX_READERS) |i| {
        const a = @atomicLoad(u64, &chan.header.readers[i], .acquire);
        if (a == 0) continue;
        for (i + 1..MAX_READERS) |k| {
            const b = @atomicLoad(u64, &chan.header.readers[k], .acquire);
            if (b == 0) continue;
            try std.testing.expect(a >> 32 != b >> 32);
        }
    }
}
