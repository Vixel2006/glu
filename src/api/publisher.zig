const std = @import("std");
const c = std.c;
const Channel = @import("../channel.zig").Channel;
const write = @import("../channel.zig").write;
const read = @import("../channel.zig").read;

pub const Publisher = struct {
    channel: Channel,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, msg_size: u32, capacity: u32) !Publisher {
        return .{ .channel = try Channel.open(allocator, name, msg_size, capacity) };
    }

    pub fn deinit(self: *Publisher) void {
        self.channel.close();
    }

    pub fn publish(self: *Publisher, comptime T: type, msg: *const T) void {
        write(&self.channel, T, msg);
    }
};

test "Publisher: publish a message, read it via raw Channel" {
    const TestMsg = packed struct { x: u32, y: u32 };
    const allocator = std.heap.page_allocator;

    var chan = try Channel.open(allocator, "/glu_test_publisher", @sizeOf(TestMsg), 5);
    defer chan.close();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open(allocator, "/glu_test_publisher", @sizeOf(TestMsg), 5) catch c.exit(1);
        var publisher = Publisher{ .channel = child_chan };
        publisher.publish(TestMsg, &.{ .x = 7, .y = 13 });
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    const msg = read(&chan, TestMsg);
    try std.testing.expect(msg.x == 7);
    try std.testing.expect(msg.y == 13);
    _ = c.waitpid(pid, null, 0);
}
