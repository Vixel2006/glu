const std = @import("std");
const c = std.c;
const Channel = @import("../channel.zig").Channel;
const Topic = @import("../topic.zig").Topic;
const read = @import("../channel.zig").read;
const write = @import("../channel.zig").write;

pub const Subscriber = struct {
    channel: Channel,

    pub fn init(allocator: std.mem.Allocator, topic: Topic) !Subscriber {
        return .{ .channel = try Channel.open(allocator, topic) };
    }

    pub fn deinit(this: *Subscriber) void {
        this.channel.close();
    }

    pub fn receive(this: *Subscriber, comptime T: type) ?*T {
        if (this.channel.header.read < this.channel.header.write) {
            return read(&this.channel, T);
        }
        return null;
    }
};

test "Subscriber: publish via raw Channel, receive via Subscriber" {
    const TestMsg = packed struct { x: u32, y: u32 };
    const topic = Topic.init("/glu_test_subscriber", @sizeOf(TestMsg), 5);
    const allocator = std.heap.page_allocator;

    const pid = c.fork();
    if (pid == 0) {
        var chan = try Channel.open(allocator, topic);
        defer chan.close();
        write(&chan, TestMsg, &.{ .x = 99, .y = 42 });
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    var sub = try Subscriber.init(allocator, topic);
    defer sub.deinit();
    const msg = sub.receive(TestMsg) orelse return error.TestFailed;
    try std.testing.expect(msg.x == 99);
    try std.testing.expect(msg.y == 42);
    _ = c.waitpid(pid, null, 0);
}
