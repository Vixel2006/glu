const std = @import("std");
const Topic = @import("../topic.zig").Topic;
const Publisher = @import("publisher.zig").Publisher;
const Subscriber = @import("subscriber.zig").Subscriber;

pub const Node = struct {
    allocator: std.mem.Allocator,
    name: []const u8,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Node {
        return .{ .allocator = allocator, .name = name };
    }

    pub fn deinit(self: *Node) void {
        _ = self;
    }

    pub fn createPublisher(self: *Node, comptime T: type, topic_name: []const u8, capacity: u32) !Publisher {
        const topic = Topic.init(topic_name, @sizeOf(T), capacity);
        return Publisher.init(self.allocator, topic);
    }

    pub fn createSubscriber(self: *Node, comptime T: type, topic_name: []const u8) !Subscriber {
        const topic = Topic.init(topic_name, @sizeOf(T), 0);
        return Subscriber.init(self.allocator, topic);
    }
};

test "Node: create publisher and subscriber via node" {
    const TestMsg = packed struct { x: u32, y: u32 };
    const allocator = std.heap.page_allocator;
    var node = Node.init(allocator, "test_node");
    defer node.deinit();

    var publisher = try node.createPublisher(TestMsg, "/glu_test_node", 5);
    defer publisher.deinit();

    var sub = try node.createSubscriber(TestMsg, "/glu_test_node");
    defer sub.deinit();

    // Verify the node name
    try std.testing.expect(std.mem.eql(u8, node.name, "test_node"));
}
