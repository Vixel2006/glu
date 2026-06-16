const std = @import("std");
const Topic = @import("topic.zig").Topic;

/// Channel is the shared memory between different nodes that will hold the topics data
/// nodes can consume messages from channels, or produce messages to it
const Channel = struct {
    topic: Topic,
};
