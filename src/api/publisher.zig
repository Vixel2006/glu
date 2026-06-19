const std = @import("std");
const c = std.c;
const Channel = @import("../channel.zig").Channel;
const Topic = @import("../topic.zig").Topic;
const write = @import("../channel.zig").write;
const read = @import("../channel.zig").read;

pub const Publisher = struct {
    channel: Channel,

    pub fn init(allocator: std.mem.Allocator, topic: Topic) !Publisher {
        return .{ .channel = try Channel.open(allocator, topic) };
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
    const topic = Topic.init("/glu_test_publisher", @sizeOf(TestMsg), 5);
    const allocator = std.heap.page_allocator;

    const pid = c.fork();
    if (pid == 0) {
        var publisher = try Publisher.init(allocator, topic);
        defer publisher.deinit();
        publisher.publish(TestMsg, &.{ .x = 7, .y = 13 });
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    var chan = try Channel.open(allocator, topic);
    defer chan.close();
    const msg = read(&chan, TestMsg);
    try std.testing.expect(msg.x == 7);
    try std.testing.expect(msg.y == 13);
    _ = c.waitpid(pid, null, 0);
}
