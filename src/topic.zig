const std = @import("std");

pub const Topic = struct {
    /// name is a string identifier for the topic
    /// it would be used as a key for the shared memory object
    name: []const u8,

    /// msg_size is the size of individual messages passing through the channel
    /// it's important to have a pre-defined message size for each topic for aligned loads and stores in the channels
    msg_size: u32,

    /// capacity is the number of allowed messages in the topic channel
    /// this variable will managing the data buffer
    capacity: u32,

    /// offset has a pointer for the next free slot for messages in the channel buffer
    offset: u32 = 0,

    pub fn init(name: []const u8, msg_size: u32, capacity: u32) Topic {
        return Topic{ .name = name, .msg_size = msg_size, .capacity = capacity };
    }

    pub fn curr(self: Topic) u32 {
        return self.offset * self.msg_size;
    }

    pub fn next(self: Topic) u32 {
        return ((self.offset + 1) % self.capacity) * self.msg_size;
    }

    pub fn commit(self: *Topic) void {
        self.offset = (self.offset + 1) % self.capacity;
    }

    pub fn size(self: Topic) u32 {
        return self.capacity * self.msg_size;
    }
};

test "init topic" {
    const topic: Topic = Topic.init("/camera/frame", 4, 3);

    try std.testing.expect(std.mem.eql(u8, "/camera/frame", topic.name));
    try std.testing.expect(topic.msg_size == 4);
    try std.testing.expect(topic.capacity == 3);
    try std.testing.expect(topic.offset == 0);
}

test "get current offset" {
    var topic: Topic = Topic.init("camera/frame", 4, 3);

    topic.commit();

    try std.testing.expect(topic.curr() == 4);
    try std.testing.expect(topic.next() == 8);
}

test "ring buffer offsets" {
    var topic: Topic = Topic.init("camera/frame", 4, 3);

    topic.commit();
    topic.commit();
    topic.commit();
    try std.testing.expect(topic.curr() == 0);

    topic.commit();
    try std.testing.expect(topic.curr() == 4);
}
