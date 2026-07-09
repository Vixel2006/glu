const std = @import("std");
const c = std.c;
const Channel = @import("../channel.zig").Channel;
const read = @import("../channel.zig").read;
const write = @import("../channel.zig").write;

const SubErr = error{
    OutOfMemory,
    ShmOpenFailed,
    MmapFailed,
};

/// High-level subscriber wrapping a raw `Channel`.
///
/// Each subscriber occupies one slot in the channel's reader array
/// (0 .. MAX_READERS-1). Multiple subscribers can attach to the
/// same topic independently.
pub const Subscriber = struct {
    channel: Channel,
    id: u32,

    /// Create a new subscriber for topic `name` with the given reader `id`.
    ///
    /// The `id` must be unique per channel and < MAX_READERS.
    /// Initialises the reader cursor to 0 (active) and self-registers.
    pub fn init(allocator: std.mem.Allocator, name: []const u8, msg_size: u32, capacity: u32) SubErr!Subscriber {
        const chan = try Channel.open(allocator, name, msg_size, capacity);

        var id: u32 = undefined;
        for(0.., chan.header.read) |i, cursor| {
            if (cursor == std.math.maxInt(u32)) {
                id = @intCast(i);
                break;
            }
        }


        const sub: Subscriber = .{ .id = id, .channel = chan };

        // Initialize read cursor to the current write position so that a late-joining
        // subscriber (e.g. a profiler that starts after the publisher) only sees new
        // messages. Setting it to 0 would cause the publisher to deadlock waiting for
        // the subscriber to drain all old ring-buffer slots that no longer exist.
        const current_write = @atomicLoad(u32, &sub.channel.header.write, .acquire);
        @atomicStore(u32, &sub.channel.header.read[sub.id], current_write, .release);

        const pid: u32 = @intCast(std.os.linux.getpid());
        @atomicStore(u32, &sub.channel.header.pids[sub.id], pid, .monotonic);

        return sub;
    }

    /// Close this subscriber and mark its reader slot as inactive.
    ///
    /// Setting the read cursor to `maxInt(u32)` removes it from the
    /// slowest-reader calculation so the publisher won't wait for us.
    pub fn deinit(self: *Subscriber) void {
        self.channel.header.read[self.id] = std.math.maxInt(u32);
        self.channel.close();
    }

    /// Try to read the next message, returning `null` if none available.
    ///
    /// Non-blocking: compares the local read cursor against the global
    /// write cursor and only advances when new data exists.
    pub fn receive(self: *Subscriber) ?*anyopaque {
        const r = @atomicLoad(u32, &self.channel.header.read[self.id], .monotonic);
        const w = @atomicLoad(u32, &self.channel.header.write, .acquire);
        if (r < w) return read(&self.channel, self.id);
        return null;
    }
};

test "Subscriber: publish via raw Channel, receive via Subscriber" {
    const TestMsg = packed struct { x: u32, y: u32 };
    const allocator = std.heap.page_allocator;

    // we do unlink to close the stale POSIX shared memory from prior failed tests if any
    _ = c.shm_unlink("/glu_test_subscriber");

    var sub = try Subscriber.init(allocator, "/glu_test_subscriber", @sizeOf(TestMsg), 2);
    defer sub.deinit();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open(allocator, "/glu_test_subscriber", @sizeOf(TestMsg), 2) catch c.exit(1);
        write(&child_chan, @ptrCast(&TestMsg{ .x = 99, .y = 42 }));
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    const msg = sub.receive() orelse return error.TestFailed;
    const msg_ptr: *const TestMsg = @ptrCast(@alignCast(msg));
    try std.testing.expect(msg_ptr.x == 99);
    try std.testing.expect(msg_ptr.y == 42);
    _ = c.waitpid(pid, null, 0);
}

test "two subscribers on the same channel both receive messages" {
    const TestMsg = packed struct { x: u32, y: u32 };
    const allocator = std.heap.page_allocator;

    _ = c.shm_unlink("/glu_test_two_subs");

    var sub0 = try Subscriber.init(allocator, "/glu_test_two_subs", @sizeOf(TestMsg), 8);
    defer sub0.deinit();
    var sub1 = try Subscriber.init(allocator, "/glu_test_two_subs", @sizeOf(TestMsg), 8);
    defer sub1.deinit();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open(allocator, "/glu_test_two_subs", @sizeOf(TestMsg), 8) catch c.exit(1);
        write(&child_chan, @ptrCast(&TestMsg{ .x = 1, .y = 2 }));
        write(&child_chan, @ptrCast(&TestMsg{ .x = 3, .y = 4 }));
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }

    const m0a = sub0.receive() orelse return error.TestFailed;
    const m0a_ptr: *const TestMsg = @ptrCast(@alignCast(m0a));
    try std.testing.expect(m0a_ptr.x == 1);
    try std.testing.expect(m0a_ptr.y == 2);

    const m0b = sub0.receive() orelse return error.TestFailed;
    const m0b_ptr: *const TestMsg = @ptrCast(@alignCast(m0b));
    try std.testing.expect(m0b_ptr.x == 3);
    try std.testing.expect(m0b_ptr.y == 4);

    const m1a = sub1.receive() orelse return error.TestFailed;
    const m1a_ptr: *const TestMsg = @ptrCast(@alignCast(m1a));
    try std.testing.expect(m1a_ptr.x == 1);
    try std.testing.expect(m1a_ptr.y == 2);

    const m1b = sub1.receive() orelse return error.TestFailed;
    const m1b_ptr: *const TestMsg = @ptrCast(@alignCast(m1b));
    try std.testing.expect(m1b_ptr.x == 3);
    try std.testing.expect(m1b_ptr.y == 4);

    _ = c.waitpid(pid, null, 0);
}
