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
pub const Channel = struct {
    /// topic variable will save the topic metadata needed to find correct shared memory objects, calculate offsets, alignments in the shared memory
    topic: Topic,

    /// fd will save the file discriptor for the shared memory object holding the channel
    /// on initializing we will create a new shm object or open the existing one and return the fd
    /// this will help us accuractly modify the correct channel independetly
    fd: i32,

    /// ptr is the pointer for the start of our shared memory object
    ptr: [*]u8,

    /// header points into shared memory — both processes see the same write/read indices
    header: *Header,

    pub fn open(allocator: std.mem.Allocator, topic: Topic) !Channel {
        const name = try allocator.dupeZ(u8, topic.name);
        defer allocator.free(name);

        const o_flags: c_int = @as(c_int, @bitCast(os.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }));

        var fd: i32 = c.shm_open(name.ptr, o_flags, 0o644);
        var created = true;

        if (fd == -1) {
            // Already exists — open without EXCL|CREAT
            const open_flags: c_int = @as(c_int, @bitCast(os.O{
                .ACCMODE = .RDWR,
            }));
            fd = c.shm_open(name.ptr, open_flags, 0);
            created = false;
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
        const hdr: *Header = @ptrCast(@alignCast(ptr));

        if (created) {
            hdr.write = 0;
            hdr.read = 0;
        }

        return Channel{ .topic = topic, .fd = fd, .ptr = ptr, .header = hdr };
    }

    pub fn close(this: @This()) void {
        _ = os.munmap(this.ptr, this.topic.size() + @sizeOf(Header));
        _ = os.close(this.fd);

        var buf: [256]u8 = undefined;
        const name = std.fmt.bufPrintZ(&buf, "{s}", .{this.topic.name}) catch return;
        _ = c.shm_unlink(name.ptr);
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

test "cross-process: producer writes, consumer reads via fork" {
    const TestMsg = packed struct { x: u32, y: u32 };
    const topic = Topic.init("/glu_test_fork", @sizeOf(TestMsg), 5);
    const allocator = std.heap.page_allocator;

    // Fork — child writes, parent reads
    const pid = c.fork();
    if (pid == 0) {
        // Child: producer
        var chan = try Channel.open(allocator, topic);
        defer chan.close();
        write(&chan, TestMsg, &TestMsg{ .x = 42, .y = 99 });
        c.exit(0);
    }

    // Parent: consumer (wait a tiny bit for child to write)
    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    var chan = try Channel.open(allocator, topic);
    defer chan.close();
    const msg = read(&chan, TestMsg);
    try std.testing.expect(msg.x == 42);
    try std.testing.expect(msg.y == 99);

    // Wait for child, clean up
    _ = c.waitpid(pid, null, 0);
}
