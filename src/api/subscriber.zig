const std = @import("std");
const c = std.c;
const Channel = @import("../channel.zig").Channel;
const read = @import("../channel.zig").read;
const write = @import("../channel.zig").write;

pub const Subscriber = struct {
    channel: Channel,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, msg_size: u32, capacity: u32) !Subscriber {
        return .{ .channel = try Channel.open(allocator, name, msg_size, capacity) };
    }

    pub fn deinit(self: *Subscriber) void {
        self.channel.close();
    }

    pub fn receive(self: *Subscriber, comptime T: type) ?*T {
        if (self.channel.header.read < self.channel.header.write) {
            return read(&self.channel, T);
        }
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
