const std = @import("std");
const zbench = @import("zbench");
const Publisher = @import("glu").Publisher;
const Subscriber = @import("glu").Subscriber;

const TestMsg = packed struct { x: u32, y: u32 };

var pub_channel: Publisher = undefined;
var sub_channel: Subscriber = undefined;
var sub_pub: Publisher = undefined;

fn beforePublisher() void {
    pub_channel = Publisher.init(std.heap.page_allocator, "/glu_bench_pub", @sizeOf(TestMsg), 4096, .reliable) catch unreachable;
}

fn afterPublisher() void {
    pub_channel.deinit();
}

fn resetPublisher() void {
    pub_channel.channel.header.write = 0;
}

fn beforeSubscriber() void {
    sub_pub = Publisher.init(std.heap.page_allocator, "/glu_bench_sub", @sizeOf(TestMsg), 16384, .reliable) catch unreachable;
    sub_channel = Subscriber.init(std.heap.page_allocator, "/glu_bench_sub", @sizeOf(TestMsg), 16384) catch unreachable;
    var i: u32 = 0;
    while (i < 16384) : (i += 1) {
        sub_pub.publish(TestMsg, &.{ .x = i, .y = i + 1 });
    }
}

fn afterSubscriber() void {
    sub_channel.deinit();
    sub_pub.deinit();
}

fn resetSubscriber() void {
    sub_channel.channel.header.read[0] = 0;
}

pub fn benchPublisherPublish(allocator: std.mem.Allocator) void {
    _ = allocator;
    pub_channel.publish(TestMsg, &.{ .x = 42, .y = 99 });
}

pub fn benchSubscriberReceive(allocator: std.mem.Allocator) void {
    _ = allocator;
    const msg = sub_channel.receive(TestMsg);
    std.mem.doNotOptimizeAway(msg);
}

pub const publish_hooks = zbench.Hooks{
    .before_all = beforePublisher,
    .after_all = afterPublisher,
    .before_each = resetPublisher,
};
pub const receive_hooks = zbench.Hooks{
    .before_all = beforeSubscriber,
    .after_all = afterSubscriber,
    .before_each = resetSubscriber,
};
