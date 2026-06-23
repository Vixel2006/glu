const std = @import("std");
const c = std.c;
const Channel = @import("../channel.zig").Channel;
const read = @import("../channel.zig").read;
const Registry = @import("../registry.zig");
const write = @import("../channel.zig").write;

pub const Subscriber = struct {
    channel: Channel,
    id: u32,

    pub fn init(allocator: std.mem.Allocator, id: u32, name: []const u8, msg_size: u32, capacity: u32) !Subscriber {
        const sub: Subscriber = .{ .id = id, .channel = try Channel.open(allocator, name, msg_size, capacity) };

        // initialize an active subscriber in the channel
        sub.channel.header.read[sub.id] = 0;
        Registry.registerOwnExe();

        return sub;
    }

    pub fn deinit(self: *Subscriber) void {
        // Assign inactive subscriber read index to max u32 so it doesn't affect the slowest reader calculation
        self.channel.header.read[self.id] = std.math.maxInt(u32);
        Registry.unregisterOwnExe();
        self.channel.close();
    }

    pub fn receive(self: *Subscriber, comptime T: type) ?*T {
        const r = @atomicLoad(u32, &self.channel.header.read[self.id], .monotonic);
        const w = @atomicLoad(u32, &self.channel.header.write, .acquire);
        if (r < w) return read(&self.channel, T, self.id);
        return null;
    }
};

test "Subscriber: publish via raw Channel, receive via Subscriber" {
    const TestMsg = packed struct { x: u32, y: u32 };
    const allocator = std.heap.page_allocator;

    // we do unlink to close the stale POSIX shared memory from prior failed tests if any
    _ = c.shm_unlink("/glu_test_subscriber");

    var sub = try Subscriber.init(allocator, 0, "/glu_test_subscriber", @sizeOf(TestMsg), 2);
    defer sub.deinit();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open(allocator, "/glu_test_subscriber", @sizeOf(TestMsg), 2) catch c.exit(1);
        write(&child_chan, TestMsg, &.{ .x = 99, .y = 42 });
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    const msg = sub.receive(TestMsg) orelse return error.TestFailed;
    try std.testing.expect(msg.x == 99);
    try std.testing.expect(msg.y == 42);
    _ = c.waitpid(pid, null, 0);
}

test "two subscribers on the same channel both receive messages" {
    const TestMsg = packed struct { x: u32, y: u32 };
    const allocator = std.heap.page_allocator;

    _ = c.shm_unlink("/glu_test_two_subs");

    var sub0 = try Subscriber.init(allocator, 0, "/glu_test_two_subs", @sizeOf(TestMsg), 8);
    defer sub0.deinit();
    var sub1 = try Subscriber.init(allocator, 1, "/glu_test_two_subs", @sizeOf(TestMsg), 8);
    defer sub1.deinit();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open(allocator, "/glu_test_two_subs", @sizeOf(TestMsg), 8) catch c.exit(1);
        write(&child_chan, TestMsg, &.{ .x = 1, .y = 2 });
        write(&child_chan, TestMsg, &.{ .x = 3, .y = 4 });
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }

    const m0a = sub0.receive(TestMsg) orelse return error.TestFailed;
    try std.testing.expect(m0a.x == 1);
    try std.testing.expect(m0a.y == 2);

    const m0b = sub0.receive(TestMsg) orelse return error.TestFailed;
    try std.testing.expect(m0b.x == 3);
    try std.testing.expect(m0b.y == 4);

    const m1a = sub1.receive(TestMsg) orelse return error.TestFailed;
    try std.testing.expect(m1a.x == 1);
    try std.testing.expect(m1a.y == 2);

    const m1b = sub1.receive(TestMsg) orelse return error.TestFailed;
    try std.testing.expect(m1b.x == 3);
    try std.testing.expect(m1b.y == 4);

    _ = c.waitpid(pid, null, 0);
}
