const std = @import("std");
const c = @import("std").c;
const os = @import("std").os.linux;
const Topic = @import("topic.zig").Topic;

const Header = packed struct {
    write: u32,
    read: u32,
};

/// Channel is the shared memory between different nodes that will hold the topics data
/// nodes can consume messages from channels, or produce messages to it
const Channel = struct {
    /// topic variable will save the topic metadata needed to find correct shared memory objects, calculate offsets, alignments in the shared memory
    topic: Topic,

    /// fd will save the file discriptor for the shared memory object holding the channel
    /// on initializing we will create a new shm object or open the existing one and return the fd
    /// this will help us accuractly modify the correct channel independetly
    fd: i32,

    /// ptr is the pointer for the start of our shared memory object
    ptr: [*]u8,

    header: Header,

    pub fn open(allocator: std.mem.Allocator, topic: Topic) !Channel {
        const name = try allocator.dupeZ(u8, topic.name);
        defer allocator.free(name);

        const o_flags: c_int = @as(c_int, @bitCast(os.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }));

        var fd: i32 = c.shm_open(name.ptr, o_flags, 0o644);

        if (fd == -1) {
            // Already exists — open without EXCL|CREAT
            const open_flags: c_int = @as(c_int, @bitCast(os.O{
                .ACCMODE = .RDWR,
            }));
            fd = c.shm_open(name.ptr, open_flags, 0);
        }

        if (fd == -1) return error.ShmOpenFailed;

        _ = c.ftruncate(fd, @intCast(topic.size() + @sizeOf(Header)));

        const size: usize = @as(usize, topic.size()) + @sizeOf(Header);

        const mapped = os.mmap(
            null,
            size,
            os.PROT{ .READ = true, .WRITE = true },
            os.MAP{ .TYPE = .SHARED },
            fd,
            0,
        );

        if (mapped == ~@as(usize, 0)) return error.MmapFailed;

        const ptr: [*]u8 = @ptrFromInt(mapped);

        return Channel{ .topic = topic, .fd = fd, .ptr = ptr, .header = .{ .read = 0, .write = 0 } };
    }

    pub fn close(this: @This()) void {
        _ = os.munmap(this.ptr, this.topic.size() + @sizeOf(Header));
        _ = os.close(this.fd);
    }
};

pub fn write(chan: *Channel, comptime T: type, msg: *const T) void {
    std.debug.assert(@sizeOf(T) == chan.topic.msg_size);

    const slot = chan.ptr + @sizeOf(Header) + chan.header.write * chan.topic.msg_size;
    @memcpy(slot, @as(*const [@sizeOf(T)]u8, @ptrCast(msg)));
    chan.header.write += 1;
}

pub fn read(chan: *Channel, comptime T: type) *T {
    std.debug.assert(@sizeOf(T) == chan.topic.msg_size);

    const slot = chan.ptr + @sizeOf(Header) + chan.header.read * chan.topic.msg_size;
    chan.header.read += 1;

    return @as(*T, @ptrCast(@alignCast(slot)));
}

test "basic round-trip: write and read a single message" {
    const TestMsg = packed struct { x: u32, y: u32 };
    const topic = Topic.init("/glu_test_roundtrip", @sizeOf(TestMsg), 3);
    const allocator = std.heap.page_allocator;

    var chan = try Channel.open(allocator, topic);
    defer chan.close();

    const sent = TestMsg{ .x = 42, .y = 99 };
    write(&chan, TestMsg, &sent);
    const received = read(&chan, TestMsg);

    try std.testing.expect(received.x == 42);
    try std.testing.expect(received.y == 99);

    const name = try allocator.dupeZ(u8, topic.name);
    defer allocator.free(name);
    _ = c.shm_unlink(name.ptr);
}
