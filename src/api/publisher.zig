const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const Shm = @import("../channel/shm.zig").Shm;
const is_alive = @import("../utils.zig").is_alive;
const force_unlink = @import("../channel/shm.zig").force_unlink;
const Header = @import("../channel/shm.zig").Header;
const ToS = @import("../channel/shm.zig").ToS;
const slowest_reader = @import("../channel/shm.zig").slowest_reader;
const sweep_dead_readers = @import("../channel/shm.zig").sweep_dead_readers;

const PubErr = error{
    OutOfMemory,
    ShmOpenFailed,
    MmapFailed,
    InvalidSegment,
    SegmentOwned,
};

pub const Publisher = struct {
    channel: Shm,

    pub fn init(name: []const u8, msg_size: u32, capacity: u32, tos: ToS) PubErr!Publisher {
        assert(msg_size > 0);
        assert(capacity > 0);
        assert(name.len > 0);
        var self = Publisher{ .channel = try Shm.open(name, msg_size, capacity, tos) };

        const my_pid = @as(u32, @intCast(std.os.linux.getpid()));
        _ = @cmpxchgStrong(u32, &self.channel.header.writer_pid, 0, my_pid, .acq_rel, .acquire);

        const writer_pid = self.channel.header.writer_pid;
        if (writer_pid != my_pid) {
            if (writer_pid != 0 and is_alive(writer_pid)) {
                // The segment belongs to a live publisher; don't link it to this publisher
                self.deinit();
                return error.SegmentOwned;
            }
            self.channel.header.writer_pid = my_pid;
        }

        return self;
    }

    pub fn deinit(self: *Publisher) void {
        self.channel.header.writer_pid = 0;
        self.channel.close();
    }

    pub fn reserve(self: *Publisher) *anyopaque {
        const cap = self.channel.cap;
        const tos = self.channel.tos;

        if (tos == .reliable) {
            while (self.channel.header.write -% slowest_reader(&self.channel.header.readers, self.channel.header.write) >= cap) {
                sweep_dead_readers(&self.channel.header.readers);
                if (self.channel.header.write -% slowest_reader(&self.channel.header.readers, self.channel.header.write) < cap) break;
                std.atomic.spinLoopHint();
            }
        }
        const slot = self.channel.ptr + @sizeOf(Header) + (self.channel.header.write % cap) * self.channel.msg_size;
        return @ptrCast(slot);
    }

    pub fn commit(self: *Publisher) void {
        _ = @atomicRmw(u32, &self.channel.header.write, .Add, 1, .release);
    }

    pub fn publish(self: *Publisher, msg: *const anyopaque) void {
        self.channel.write(msg);
    }
};

test "Publisher: reserve and commit directly" {
    const TestMsg = packed struct { x: u32, y: u32 };

    _ = c.shm_unlink("/glu_test_reserve");

    var chan = try Shm.open("/glu_test_reserve", @sizeOf(TestMsg), 5, .reliable);
    defer chan.close();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Shm.open("/glu_test_reserve", @sizeOf(TestMsg), 5, .reliable) catch c.exit(1);
        var publisher = Publisher{ .channel = child_chan };
        const slot: *TestMsg = @ptrCast(@alignCast(publisher.reserve()));
        slot.* = TestMsg{ .x = 42, .y = 99 };
        publisher.commit();
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    const msg: *const TestMsg = @ptrCast(@alignCast(chan.peek(0)));
    try std.testing.expect(msg.x == 42);
    try std.testing.expect(msg.y == 99);
    chan.ack(0);
    _ = c.waitpid(pid, null, 0);
}

test "Publisher: publish a message, read it via raw Shm" {
    const TestMsg = packed struct { x: u32, y: u32 };

    var chan = try Shm.open("/glu_test_publisher", @sizeOf(TestMsg), 5, .reliable);
    defer chan.close();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Shm.open("/glu_test_publisher", @sizeOf(TestMsg), 5, .reliable) catch c.exit(1);
        var publisher = Publisher{ .channel = child_chan };
        publisher.publish(@ptrCast(&TestMsg{ .x = 7, .y = 13 }));
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    const msg: *const TestMsg = @ptrCast(@alignCast(chan.peek(0)));
    try std.testing.expect(msg.x == 7);
    try std.testing.expect(msg.y == 13);
    chan.ack(0);
    _ = c.waitpid(pid, null, 0);
}
