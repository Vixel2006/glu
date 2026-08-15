const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const Shm = @import("../channel/shm.zig").Shm;
const force_unlink = @import("../channel/shm.zig").force_unlink;
const Header = @import("../channel/shm.zig").Header;
const ToS = @import("../channel/shm.zig").ToS;
const is_alive = @import("../registry.zig").is_alive;
const slowest_reader = @import("../channel/shm.zig").slowest_reader;
const sweep_dead_readers = @import("../channel/shm.zig").sweep_dead_readers;

const PubErr = error{
    OutOfMemory,
    ShmOpenFailed,
    MmapFailed,
    InvalidSegment,
    /// The topic's segment is owned by a live publisher. Only one publisher
    /// per topic is allowed.
    SegmentOwned,
};

/// High-level publisher wrapping a raw `Shm`.
///
/// Each topic can have at most one publisher. The publisher attaches to
/// an existing segment or creates one if none exists. Unlinks on `deinit`.
pub const Publisher = struct {
    channel: Shm,

    /// Create (or attach to) a shared-memory channel for topic `name`.
    ///
    /// If the existing segment belongs to a live publisher a
    /// `SegmentOwned` error is returned: a topic has at most one
    /// publisher. A segment whose owner is dead or unknown is treated as
    /// a stale leak (crashed publisher whose `conns` count could never be
    /// decremented) and a fresh channel is created.
    pub fn init(name: []const u8, msg_size: u32, capacity: u32, tos: ToS) PubErr!Publisher {
        assert(msg_size > 0);
        assert(capacity > 0);
        assert(name.len > 0);
        var self = Publisher{ .channel = try Shm.open(name, msg_size, capacity, tos) };

        const my_pid = @as(u32, @intCast(std.os.linux.getpid()));
        _ = @cmpxchgStrong(u32, &self.channel.header.owner_pid, 0, my_pid, .acq_rel, .acquire);

        const owner_pid = self.channel.header.owner_pid;
        if (owner_pid != my_pid) {
            if (owner_pid != 0 and is_alive(owner_pid)) {
                // The segment belongs to a live publisher; don't destroy it.
                self.deinit();
                return error.SegmentOwned;
            }
            // The refcount can't tell a crashed publisher from a live one,
            // so base staleness on owner liveness instead. Unlink the
            // orphaned segment and recreate it fresh.
            force_unlink(name);
            self.deinit();
            return Publisher{ .channel = try Shm.open(name, msg_size, capacity, tos) };
        }

        return self;
    }

    pub fn deinit(self: *Publisher) void {
        self.channel.close();
    }

    /// Reserve a slot in the ring buffer for writing.
    ///
    /// This is the first half of the two-phase publish pattern.
    /// Fill the returned pointer then call `commit` to make the
    /// message visible to subscribers. Blocks if the buffer is full.
    pub fn reserve(self: *Publisher) *anyopaque {
        const cap = self.channel.cap;
        const tos = self.channel.tos;

        if (tos == .reliable) {
            while (self.channel.header.write -% slowest_reader(&self.channel.header.readers, self.channel.header.write) >= cap) {
                sweep_dead_readers(&self.channel.header.readers);
                if (self.channel.header.write -% slowest_reader(&self.channel.header.readers, self.channel.header.write) < cap) break;
                std.atomic.spinLoopHint();
            }
        }
        const slot = self.channel.ptr + @sizeOf(Header) + (self.channel.header.write % cap) * self.channel.msg_size;
        return @ptrCast(slot);
    }

    /// Commit a reserved slot, making it visible to subscribers.
    ///
    /// Must be paired with a prior `reserve` call. Advances the write
    /// cursor with a release store so readers see the written data.
    pub fn commit(self: *Publisher) void {
        _ = @atomicRmw(u32, &self.channel.header.write, .Add, 1, .release);
    }

    /// Write a message in one shot (reserve + copy + commit).
    pub fn publish(self: *Publisher, msg: *const anyopaque) void {
        self.channel.write(msg);
    }
};

test "Publisher: reserve and commit directly" {
    const TestMsg = packed struct { x: u32, y: u32 };

    _ = c.shm_unlink("/glu_test_reserve");

    var chan = try Shm.open("/glu_test_reserve", @sizeOf(TestMsg), 5, .reliable);
    defer chan.close();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Shm.open("/glu_test_reserve", @sizeOf(TestMsg), 5, .reliable) catch c.exit(1);
        var publisher = Publisher{ .channel = child_chan };
        const slot: *TestMsg = @ptrCast(@alignCast(publisher.reserve()));
        slot.* = TestMsg{ .x = 42, .y = 99 };
        publisher.commit();
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    const msg: *const TestMsg = @ptrCast(@alignCast(chan.peek(0)));
    try std.testing.expect(msg.x == 42);
    try std.testing.expect(msg.y == 99);
    chan.ack(0);
    _ = c.waitpid(pid, null, 0);
}

test "Publisher: publish a message, read it via raw Shm" {
    const TestMsg = packed struct { x: u32, y: u32 };

    var chan = try Shm.open("/glu_test_publisher", @sizeOf(TestMsg), 5, .reliable);
    defer chan.close();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Shm.open("/glu_test_publisher", @sizeOf(TestMsg), 5, .reliable) catch c.exit(1);
        var publisher = Publisher{ .channel = child_chan };
        publisher.publish(@ptrCast(&TestMsg{ .x = 7, .y = 13 }));
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    const msg: *const TestMsg = @ptrCast(@alignCast(chan.peek(0)));
    try std.testing.expect(msg.x == 7);
    try std.testing.expect(msg.y == 13);
    chan.ack(0);
    _ = c.waitpid(pid, null, 0);
}

test "Publisher.init rejects a segment owned by a live publisher" {
    const TestMsg = packed struct { x: u32 };

    _ = c.shm_unlink("/glu_test_live_owner");

    // Parent creates the segment (itself the live owner).
    var base = try Shm.open("/glu_test_live_owner", @sizeOf(TestMsg), 4, .reliable);
    defer base.close();

    const pid = c.fork();
    if (pid == 0) {
        // Child attempts to become publisher on a topic a live process owns.
        _ = Publisher.init("/glu_test_live_owner", @sizeOf(TestMsg), 4, .reliable) catch {
            c.exit(0);
        };
        c.exit(1);
    }
    _ = c.waitpid(pid, null, 0);

    // Segment must be untouched: same cursor, same owner.
    try std.testing.expectEqual(@as(u32, 0), @atomicLoad(u32, &base.header.write, .acquire));
    try std.testing.expectEqual(@as(u32, @intCast(std.os.linux.getpid())), base.header.owner_pid);
}

test "Publisher.init does not destroy a segment with alive readers but dead owner" {
    const TestMsg = packed struct { x: u32 };

    _ = c.shm_unlink("/glu_test_dead_owner_readers");

    // Simulate a crashed publisher with an orphaned but readable segment.
    const pid = c.fork();
    if (pid == 0) {
        var chan = Shm.open("/glu_test_dead_owner_readers", @sizeOf(TestMsg), 4, .reliable) catch c.exit(1);
        chan.write(@ptrCast(&TestMsg{ .x = 42 }));
        c.exit(0);
    }
    _ = c.waitpid(pid, null, 0);

    var publisher = try Publisher.init("/glu_test_dead_owner_readers", @sizeOf(TestMsg), 4, .reliable);
    defer publisher.deinit();

    try std.testing.expectEqual(@as(u32, 0), publisher.channel.header.write);
}

test "Publisher.init reclaims a segment left by a crashed publisher" {
    const TestMsg = packed struct { x: u32 };

    _ = c.shm_unlink("/glu_test_stale_reclaim");

    // Simulate a crashed publisher: open the channel, write a message and
    // exit without closing, so `conns` is left elevated and the segment
    // could never be reclaimed by refcounting alone.
    const pid = c.fork();
    if (pid == 0) {
        var chan = Shm.open("/glu_test_stale_reclaim", @sizeOf(TestMsg), 4, .reliable) catch c.exit(1);
        chan.write(@ptrCast(&TestMsg{ .x = 42 }));
        c.exit(0);
    }
    _ = c.waitpid(pid, null, 0);

    var publisher = try Publisher.init("/glu_test_stale_reclaim", @sizeOf(TestMsg), 4, .reliable);
    defer publisher.deinit();

    // A fresh segment is created: the write cursor is reset and the
    // configured message size / capacity are restored.
    try std.testing.expectEqual(@as(u32, 0), publisher.channel.header.write);
    try std.testing.expectEqual(@as(u32, @sizeOf(TestMsg)), publisher.channel.header.msg_size);
    try std.testing.expectEqual(@as(u32, 4), publisher.channel.header.capacity);
}
