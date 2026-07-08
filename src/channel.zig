const std = @import("std");
const c = @import("std").c;
const os = @import("std").os.linux;

const ShmErr = error{
    OutOfMemory,
    ShmOpenFailed,
    MmapFailed
};

/// Magic number used to identify glu shared memory segments (`0x474C5500` = "GLU\0").
pub const GLU_MAGIC = 0x474C5500;
/// Maximum number of concurrent readers (subscribers) per channel.
pub const MAX_READERS = 8;

/// Layout of the shared memory header at the start of every channel.
///
/// The `name` field is padded to 64 bytes to push the `read` array past
/// the first cache line, reducing false sharing between writer and readers.
pub const Header = extern struct {
    magic: u32 = GLU_MAGIC,
    write: u32,
    conns: u32,
    msg_size: u32,
    capacity: u32,
    name_len: u32,
    name: [64]u8,
    read: [MAX_READERS]u32,
    // TODO: I think we maybe need to add a QoS handler here that should go to (0 = best-effort (don't care about slowest reader.), 1=reliable(the one we have now), 2=)
};

comptime {
    std.debug.assert(@sizeOf(Header) == 120);
}

/// A POSIX shared-memory channel backed by `shm_open` + `mmap`.
///
/// Multiple processes can open the same named channel. The first opener
/// creates and initialises the segment; subsequent openers attach to it
/// and increment a reference counter. The last `close` unlinks the shm.
pub const Channel = struct {
    fd: i32,
    ptr: [*]u8,
    header: *Header,
    size: usize,

    /// Open (or attach to) a named shared memory channel.
    ///
    /// The first call with a given `name` creates the segment and
    /// initialises the header. Subsequent calls attach to the existing
    /// segment and bump the connection counter.
    pub fn open(allocator: std.mem.Allocator, name: []const u8, msg_size: u32, capacity: u32) ShmErr!Channel {
        // POSIX shm_open requires the name to start with '/' and contain
        // no other '/' characters.  Replace inner slashes with '_' so that
        // topic names like "/farm/weather" produce a valid shm name.
        const shm_name = try allocator.alloc(u8, name.len);
        defer allocator.free(shm_name);
        for (name, 0..) |ch, i| {
            shm_name[i] = if (i > 0 and ch == '/') '_' else ch;
        }
        const name_z = try allocator.dupeZ(u8, shm_name);
        defer allocator.free(name_z);

        // Attempt to create the segment exclusively.
        const excl_flags: c_int = @as(c_int, @bitCast(os.O{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .EXCL = true,
        }));
        var fd: i32 = c.shm_open(name_z.ptr, excl_flags, 0o644);
        var created = true;

        if (fd == -1) {
            // shm_open failed with O_EXCL.  If the file already exists
            // (EEXIST) we attach to it; any other error is terminal.
            const rdwr_flags: c_int = @as(c_int, @bitCast(os.O{
                .ACCMODE = .RDWR,
            }));
            fd = c.shm_open(name_z.ptr, rdwr_flags, 0);
            created = false;
        }

        if (fd == -1) return ShmErr.ShmOpenFailed;

        const data_size = msg_size * capacity;
        const total_size: usize = data_size + @sizeOf(Header);
        const map_size: usize = total_size;

        // Only the creator sets the size. Attachers trust the existing layout.
        if (created) {
            _ = c.ftruncate(fd, @intCast(total_size));
        }

        const mapped = os.mmap(
            null,
            map_size,
            os.PROT{ .READ = true, .WRITE = true },
            os.MAP{ .TYPE = .SHARED },
            fd,
            0,
        );

        if (mapped == ~@as(usize, 0)) return ShmErr.MmapFailed;

        const ptr: [*]u8 = @ptrFromInt(mapped);
        const hdr: *Header = @ptrCast(@alignCast(ptr));

        if (created) {
            hdr.magic = GLU_MAGIC;
            hdr.write = 0;
            for (&hdr.read) |*r| r.* = std.math.maxInt(u32);
            hdr.conns = 1;
            hdr.msg_size = msg_size;
            hdr.capacity = capacity;
            const name_len = @min(@as(u32, @intCast(name.len)), 63);
            hdr.name_len = name_len;
            @memcpy(hdr.name[0..name_len], name[0..name_len]);
            hdr.name[name_len] = 0;
        } else {
            _ = @atomicRmw(u32, &hdr.conns, .Add, 1, .acq_rel);
        }

        return .{ .fd = fd, .ptr = ptr, .header = hdr, .size = map_size };
    }

    /// Close this channel handle and unmap the shared memory.
    ///
    /// The underlying POSIX shm is unlinked only when the last connection
    /// is closed (reference counting via `conns`).
    pub fn close(self: *Channel) void {
        const prev = @atomicRmw(u32, &self.header.conns, .Sub, 1, .acq_rel);

        const needs_unlink = prev == 1;
        var name_buf: [256]u8 = undefined;
        const name_z: ?[:0]u8 = if (needs_unlink) blk: {
            const name_slice = self.header.name[0..self.header.name_len];
            // Re-apply the same sanitisation as open(): replace inner '/' with '_'.
            for (name_slice, 0..) |ch, i| {
                name_buf[i] = if (i > 0 and ch == '/') '_' else ch;
            }
            name_buf[name_slice.len] = 0;
            break :blk name_buf[0..name_slice.len :0];
        } else null;

        _ = os.munmap(self.ptr, self.size);
        _ = os.close(self.fd);

        if (name_z) |nz| _ = c.shm_unlink(nz.ptr);
    }

    pub const deinit = close;
};

/// Returns the slowest (smallest) active read cursor.
///
/// Inactive readers (those with `maxInt(u32)`) are skipped so they don't
/// block the writer. If no readers are active the write cursor itself is
/// returned, meaning the writer will never be held back.
pub fn slowestReader(readers: []const u32, write_cursor: u32) u32 {
    // FIXME: Here if a reader crashes the read cursor freezes and publisher will spin-wait forever
    // we should implement a mechanism in the subscribers that makes it crashes without a deadlock
    var min = write_cursor;
    for (readers) |reader| {
        if (reader != std.math.maxInt(u32)) {
            min = @min(min, reader);
        }
    }
    return min;
}

/// Write a message into the ring buffer.
///
/// Uses `chan.header.msg_size` so a single entry point serves both Zig
/// and C callers without type-level polymorphism.
/// Blocks with a spin-loop if the buffer is full (slowest-reader
/// backpressure).
pub fn write(chan: *Channel, msg: *const anyopaque) void {
    const cap = chan.header.capacity;

    // TODO: This waiting loop is basically a quality of service (QoS) feature.
    // we should have a mechanism to give the programmer control if they want to do the block
    // or they want the writer to just continue writing and maybe do reseting to the slowest reader pointer
    while (chan.header.write -% slowestReader(&chan.header.read, chan.header.write) >= cap)
        // TODO: here we do yield from the writer if the slowest reader isn't catching up
        // we should be able to implement a semaphore or condition variables for maximum performance
        std.atomic.spinLoopHint();

    const msg_size = chan.header.msg_size;
    const slot = chan.ptr + @sizeOf(Header) + (chan.header.write % cap) * msg_size;
    @memcpy(slot, @as([*]const u8, @ptrCast(msg))[0..msg_size]);

    // Publish the slot: make data visible to readers before advancing the cursor.
    _ = @atomicRmw(u32, &chan.header.write, .Add, 1, .release);
}

/// Advance the read cursor for `sub_id` and return a pointer to the slot.
///
/// Each subscriber owns one slot in the `read` array and their cursor
/// is advanced atomically. Slots are reused once all subscribers have
/// read or dropped them.
pub fn read(chan: *Channel, sub_id: u32) *anyopaque {
    const msg_size = chan.header.msg_size;
    const idx = @atomicRmw(u32, &chan.header.read[sub_id], .Add, 1, .acquire) % chan.header.capacity;
    const slot = chan.ptr + @sizeOf(Header) + idx * msg_size;
    return @ptrCast(slot);
}

test "slowestReader: skips inactive MAX_U32 readers" {
    const readers = [_]u32{ 5, std.math.maxInt(u32), 3, std.math.maxInt(u32), 10, std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) };
    try std.testing.expectEqual(@as(u32, 3), slowestReader(&readers, 100));
}

test "slowestReader: returns write cursor when no active readers" {
    const readers = [_]u32{std.math.maxInt(u32)} ** MAX_READERS;
    try std.testing.expectEqual(@as(u32, 42), slowestReader(&readers, 42));
}

test "slowestReader: active reader lower than write cursor is selected" {
    const readers = [_]u32{ std.math.maxInt(u32), 2, std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) };
    try std.testing.expectEqual(@as(u32, 2), slowestReader(&readers, 10));
}

test "writer not blocked when no active readers" {
    const TestMsg = packed struct { x: u32, y: u32 };
    const allocator = std.heap.page_allocator;

    _ = c.shm_unlink("/glu_test_nowriterblock");

    var chan = try Channel.open(allocator, "/glu_test_nowriterblock", @sizeOf(TestMsg), 2);
    defer chan.close();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open(allocator, "/glu_test_nowriterblock", @sizeOf(TestMsg), 2) catch c.exit(1);
        write(&child_chan, @ptrCast(&TestMsg{ .x = 1, .y = 1 }));
        write(&child_chan, @ptrCast(&TestMsg{ .x = 2, .y = 2 }));
        write(&child_chan, @ptrCast(&TestMsg{ .x = 3, .y = 3 }));
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }

    try std.testing.expectEqual(@as(u32, 3), @atomicLoad(u32, &chan.header.write, .acquire));
    _ = c.waitpid(pid, null, 0);
}

test "two readers read independently from the same channel" {
    const TestMsg = packed struct { x: u32, y: u32 };
    const allocator = std.heap.page_allocator;

    _ = c.shm_unlink("/glu_test_two_readers");

    var chan = try Channel.open(allocator, "/glu_test_two_readers", @sizeOf(TestMsg), 8);
    defer chan.close();

    @atomicStore(u32, &chan.header.read[0], 0, .release);

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open(allocator, "/glu_test_two_readers", @sizeOf(TestMsg), 8) catch c.exit(1);
        @atomicStore(u32, &child_chan.header.read[1], 0, .release);

        {
            var ts = std.c.timespec{ .sec = 0, .nsec = 50_000_000 };
            _ = c.nanosleep(&ts, null);
        }

        const m0: *const TestMsg = @ptrCast(@alignCast(read(&child_chan, 1)));
        const m1: *const TestMsg = @ptrCast(@alignCast(read(&child_chan, 1)));
        if (m0.x != 10 or m0.y != 20) c.exit(1);
        if (m1.x != 30 or m1.y != 40) c.exit(1);

        child_chan.close();
        c.exit(0);
    }

    write(&chan, @ptrCast(&TestMsg{ .x = 10, .y = 20 }));
    write(&chan, @ptrCast(&TestMsg{ .x = 30, .y = 40 }));

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 50_000_000 };
        _ = c.nanosleep(&ts, null);
    }

    const m0: *const TestMsg = @ptrCast(@alignCast(read(&chan, 0)));
    try std.testing.expect(m0.x == 10);
    try std.testing.expect(m0.y == 20);
    const m1: *const TestMsg = @ptrCast(@alignCast(read(&chan, 0)));
    try std.testing.expect(m1.x == 30);
    try std.testing.expect(m1.y == 40);

    _ = c.waitpid(pid, null, 0);
}

test "cross-process: producer writes, consumer reads via fork" {
    const TestMsg = packed struct { x: u32, y: u32 };
    const allocator = std.heap.page_allocator;

    _ = c.shm_unlink("/glu_test_fork");

    var chan = try Channel.open(allocator, "/glu_test_fork", @sizeOf(TestMsg), 5);
    defer chan.close();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open(allocator, "/glu_test_fork", @sizeOf(TestMsg), 5) catch c.exit(1);
        write(&child_chan, @ptrCast(&TestMsg{ .x = 42, .y = 99 }));
        child_chan.close();
        c.exit(0);
    }

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 100_000_000 };
        _ = c.nanosleep(&ts, null);
    }
    const msg: *const TestMsg = @ptrCast(@alignCast(read(&chan, 0)));
    try std.testing.expect(msg.x == 42);
    try std.testing.expect(msg.y == 99);

    _ = c.waitpid(pid, null, 0);
}
