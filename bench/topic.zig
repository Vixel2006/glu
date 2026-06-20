const std = @import("std");
const Topic = @import("glu").Topic;

pub fn benchTopicInit(allocator: std.mem.Allocator) void {
    _ = allocator;
    var topic = Topic.init("/bench/topic_init", 64, 128);
    std.mem.doNotOptimizeAway(&topic);
}

pub fn benchTopicCommit(allocator: std.mem.Allocator) void {
    _ = allocator;
    var topic = Topic.init("/bench/topic_commit", 64, 128);
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        topic.commit();
    }
    std.mem.doNotOptimizeAway(&topic);
}

pub fn benchTopicCurr(allocator: std.mem.Allocator) void {
    _ = allocator;
    var topic = Topic.init("/bench/topic_curr", 64, 128);
    var sum: u32 = 0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        sum += topic.curr();
        topic.commit();
    }
    std.mem.doNotOptimizeAway(&sum);
}

pub fn benchTopicSize(allocator: std.mem.Allocator) void {
    _ = allocator;
    var total: u32 = 0;
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const topic = Topic.init("/bench/topic_size", 64 + i, 128 + i);
        total += topic.size();
    }
    std.mem.doNotOptimizeAway(&total);
}
