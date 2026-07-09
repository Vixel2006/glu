const std = @import("std");
const c = std.c;
const Channel = @import("../channel.zig").Channel;
const Header = @import("../channel.zig").Header;
const slowestReader = @import("../channel.zig").slowestReader;
const sweepDeadReaders = @import("../channel.zig").sweepDeadReaders;
const write = @import("../channel.zig").write;
const read = @import("../channel.zig").read;

const PubErr = error{
    OutOfMemory,
    ShmOpenFailed,
    MmapFailed,
};

/// High-level publisher wrapping a raw `Channel`.
///
/// Each topic can have at most one publisher. The publisher owns the
/// shared memory segment (creates it on `init`, unlinks on `deinit`).
pub const Publisher = struct {
    channel: Channel,

    /// Create a new publisher for topic `name`.
    ///
    /// Shm-unlinks any stale segment first, then creates a fresh channel.
    /// Self-registers the process in the node registry.
    pub fn init(allocator: std.mem.Allocator, name: []const u8, msg_size: u32, capacity: u32) PubErr!Publisher {
        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);
        _ = c.shm_unlink(name_z.ptr);
        return Publisher{ .channel = try Channel.open(allocator, name, msg_size, capacity) };
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
        while (self.channel.header.write -% slowestReader(&self.channel.header.read, self.channel.header.write) >= self.channel.header.capacity) {
            sweepDeadReaders(&self.channel.header.read, &self.channel.header.pids);
            if (self.channel.header.write -% slowestReader(&self.channel.header.read, self.channel.header.write) < self.channel.header.capacity) break;
            std.atomic.spinLoopHint();
        }
        const slot = self.channel.ptr + @sizeOf(Header) + (self.channel.header.write % self.channel.header.capacity) * self.channel.header.msg_size;
        return @ptrCast(slot);
    }

    /// Commit a reserved slot, making it visible to subscribers.
    ///
    /// Must be paired with a prior `reserve` call. Advances the write
    /// cursor with a release store so readers see the written data.
    pub fn commit(self: *Publisher) void {
        @atomicStore(u32, &self.channel.header.write, self.channel.header.write + 1, .release);
    }

    /// Write a message in one shot (reserve + copy + commit).
    pub fn publish(self: *Publisher, msg: *const anyopaque) void {
        write(&self.channel, msg);
    }
};

test "Publisher: reserve and commit directly" {
    const TestMsg = packed struct { x: u32, y: u32 };
    const allocator = std.heap.page_allocator;

    _ = c.shm_unlink("/glu_test_reserve");

    var chan = try Channel.open(allocator, "/glu_test_reserve", @sizeOf(TestMsg), 5);
    defer chan.close();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open(allocator, "/glu_test_reserve", @sizeOf(TestMsg), 5) catch c.exit(1);
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
    const msg: *const TestMsg = @ptrCast(@alignCast(read(&chan, 0)));
    try std.testing.expect(msg.x == 42);
    try std.testing.expect(msg.y == 99);
    _ = c.waitpid(pid, null, 0);
}

test "Publisher: publish a message, read it via raw Channel" {
    const TestMsg = packed struct { x: u32, y: u32 };
    const allocator = std.heap.page_allocator;

    var chan = try Channel.open(allocator, "/glu_test_publisher", @sizeOf(TestMsg), 5);
    defer chan.close();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open(allocator, "/glu_test_publisher", @sizeOf(TestMsg), 5) catch c.exit(1);
        var publisher = Publisher{ .channel = child_chan };
        publisher.publish(@ptrCast(&TestMsg{ .x = 7, .y = 13 }));
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    const msg: *const TestMsg = @ptrCast(@alignCast(read(&chan, 0)));
    try std.testing.expect(msg.x == 7);
    try std.testing.expect(msg.y == 13);
    _ = c.waitpid(pid, null, 0);
}
