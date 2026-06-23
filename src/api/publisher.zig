const std = @import("std");
const c = std.c;
const Channel = @import("../channel.zig").Channel;
const Header = @import("../channel.zig").Header;
const slowestReader = @import("../channel.zig").slowestReader;
const write = @import("../channel.zig").write;
const Registry = @import("../registry.zig");
const read = @import("../channel.zig").read;

pub const Publisher = struct {
    channel: Channel,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, msg_size: u32, capacity: u32) !Publisher {
        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);
        _ = c.shm_unlink(name_z.ptr);
        const p = Publisher{ .channel = try Channel.open(allocator, name, msg_size, capacity) };
        Registry.registerOwnExe();
        return p;
    }

    pub fn deinit(self: *Publisher) void {
        Registry.unregisterOwnExe();
        self.channel.close();
    }
    pub fn reserve(self: *Publisher, comptime T: type) *T {
        while (self.channel.header.write -% slowestReader(&self.channel.header.read, self.channel.header.write) >= self.channel.header.capacity)
            std.atomic.spinLoopHint();
        const slot = self.channel.ptr + @sizeOf(Header) + (self.channel.header.write % self.channel.header.capacity) * self.channel.header.msg_size;
        return @ptrCast(@alignCast(slot));
    }

    pub fn commit(self: *Publisher) void {
        @atomicStore(u32, &self.channel.header.write, self.channel.header.write + 1, .release);
    }

    pub fn publish(self: *Publisher, comptime T: type, msg: *const T) void {
        write(&self.channel, T, msg);
    }
};

test "Publisher: reserve and commit directly" {
    const TestMsg = packed struct { x: u32, y: u32 };
    const allocator = std.heap.page_allocator;

    _ = c.shm_unlink("/glu_test_reserve");

    var chan = try Channel.open(allocator, "/glu_test_reserve", @sizeOf(TestMsg), 5);
    defer chan.close();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open(allocator, "/glu_test_reserve", @sizeOf(TestMsg), 5) catch c.exit(1);
        var publisher = Publisher{ .channel = child_chan };
        const slot = publisher.reserve(TestMsg);
        slot.* = TestMsg{ .x = 42, .y = 99 };
        publisher.commit();
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    const msg = read(&chan, TestMsg, 0);
    try std.testing.expect(msg.x == 42);
    try std.testing.expect(msg.y == 99);
    _ = c.waitpid(pid, null, 0);
}

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
    const msg = read(&chan, TestMsg, 0);
    try std.testing.expect(msg.x == 7);
    try std.testing.expect(msg.y == 13);
    _ = c.waitpid(pid, null, 0);
}
