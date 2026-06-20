const std = @import("std");
const Publisher = @import("publisher.zig").Publisher;
const Subscriber = @import("subscriber.zig").Subscriber;
const Registry = @import("../registry.zig");

pub const Node = struct {
    allocator: std.mem.Allocator,
    name: []const u8,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Node {
        Registry.register(name) catch {};
        return .{ .allocator = allocator, .name = name };
    }

    pub fn deinit(self: *Node) void {
        Registry.unregister(self.name);
    }

    pub fn createPublisher(self: *Node, comptime T: type, topic_name: []const u8, capacity: u32) !Publisher {
        return Publisher.init(self.allocator, topic_name, @sizeOf(T), capacity);
    }

    pub fn createSubscriber(self: *Node, comptime T: type, topic_name: []const u8) !Subscriber {
        return Subscriber.init(self.allocator, topic_name, @sizeOf(T));
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

    try std.testing.expect(std.mem.eql(u8, node.name, "test_node"));
}
