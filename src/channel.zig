const std = @import("std");
const assert = std.debug.assert;
const c = @import("std").c;
const os = @import("std").os.linux;

const is_alive = @import("registry.zig").is_alive;

const ShmErr = error{ OutOfMemory, ShmOpenFailed, MmapFailed, InvalidSegment };

/// Sanitise a topic name into a valid POSIX shm name.
///
/// POSIX `shm_open` requires the name to start with '/' and contain no
/// other '/' characters, so inner slashes (topic paths like
/// `/farm/weather`) are replaced with '_'.
fn shm_name(buf: []u8, name: []const u8) ?[:0]u8 {
    if (name.len >= buf.len) return null;
    for (name, 0..) |ch, i| {
        buf[i] = if (i > 0 and ch == '/') '_' else ch;
    }
    buf[name.len] = 0;
    return buf[0..name.len :0];
}

/// Magic number used to identify glu shared memory segments (`0x474C5500` = "GLU\0").
pub const GLU_MAGIC = 0x474C5500;
/// Maximum number of concurrent readers (subscribers) per channel.
pub const MAX_READERS = 8;

/// Type of Service for channel delivery semantics.
pub const ToS = enum(u32) {
    reliable = 0,
    best_effort = 1,
};

/// Layout of the shared memory header at the start of every channel.
///
/// The `name` field is padded to 64 bytes to push the `readers` array past
/// the first cache line, reducing false sharing between writer and readers.
///
/// Each element of `readers` packs the owning subscriber PID in the high
/// 32 bits and the subscriber's read cursor in the low 32 bits. A zero
/// entry means the slot is unclaimed. Packing PID and cursor into a single
/// 64-bit word lets a subscriber claim a slot with one atomic compare-and-swap,
/// so `sweep_dead_readers` can never observe a stale PID on a freshly
/// claimed slot.
pub const Header = extern struct {
    magic: u32 = GLU_MAGIC,
    write: u32,
    conns: u32,
    msg_size: u32,
    capacity: u32,
    tos: u32,
    _pad: u32,
    name_len: u32,
    name: [64]u8,
    /// PID of the process that created this segment (0 = unknown/foreign).
    owner_pid: u32,
    _pad2: u32,
    /// Per-subscriber entries: high 32 bits = owning subscriber PID
    /// (0 = unowned/inactive), low 32 bits = read cursor.
    readers: [MAX_READERS]u64,
};

comptime {
    std.debug.assert(MAX_READERS > 0 and MAX_READERS <= 8);
    std.debug.assert(@sizeOf(Header) == 168);
    std.debug.assert(@offsetOf(Header, "owner_pid") == 96);
    std.debug.assert(@offsetOf(Header, "readers") == 104);
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
    pub fn open(name: []const u8, msg_size: u32, capacity: u32, tos: ToS) ShmErr!Channel {
        assert(msg_size > 0);
        assert(capacity > 0);
        assert(name.len > 0);
        // The data region is `msg_size * capacity` bytes. Compute it in u64
        // (a u32 product silently overflows for large configurations) and
        // reject sizes that would not fit the `off_t` used by `ftruncate`.
        const data_size = std.math.mul(u64, msg_size, capacity) catch return ShmErr.InvalidSegment;
        const total_size = std.math.add(u64, data_size, @sizeOf(Header)) catch return ShmErr.InvalidSegment;
        if (total_size > std.math.maxInt(std.c.off_t) or total_size > std.math.maxInt(usize)) {
            return ShmErr.InvalidSegment;
        }
        const total_size_usize: usize = @intCast(total_size);

        // POSIX shm_open requires the name to start with '/' and contain
        // no other '/' characters.  Replace inner slashes with '_' so that
        // topic names like "/farm/weather" produce a valid shm name.
        var shm_name_buf: [256:0]u8 = undefined;
        const shm_name_z = shm_name(&shm_name_buf, name) orelse return ShmErr.ShmOpenFailed;

        // Attempt to create the segment exclusively.
        const excl_flags: c_int = @as(c_int, @bitCast(os.O{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .EXCL = true,
        }));
        var fd: i32 = c.shm_open(shm_name_z.ptr, excl_flags, 0o644);
        var created = true;

        if (fd == -1) {
            // shm_open failed with O_EXCL.  If the file already exists
            // (EEXIST) we attach to it; any other error is terminal.
            const rdwr_flags: c_int = @as(c_int, @bitCast(os.O{
                .ACCMODE = .RDWR,
            }));
            fd = c.shm_open(shm_name_z.ptr, rdwr_flags, 0);
            created = false;
        }

        if (fd == -1) return ShmErr.ShmOpenFailed;

        // Only the creator sets the size. Attachers trust the existing layout
        // but must verify the header before trusting anything in shared memory.
        if (created) {
            if (c.ftruncate(fd, @intCast(total_size)) == -1) {
                _ = c.close(fd);
                // Don't leak a half-created segment in /dev/shm.
                _ = c.shm_unlink(shm_name_z.ptr);
                return ShmErr.ShmOpenFailed;
            }
        } else {
            const file_size = c.lseek(fd, 0, 2);
            if (file_size < @as(std.c.off_t, @intCast(@sizeOf(Header)))) {
                _ = c.close(fd);
                return ShmErr.InvalidSegment;
            }
        }

        const mapped = os.mmap(
            null,
            total_size_usize,
            os.PROT{ .READ = true, .WRITE = true },
            os.MAP{ .TYPE = .SHARED },
            fd,
            0,
        );

        if (mapped == ~@as(usize, 0)) {
            _ = c.close(fd);
            if (created) _ = c.shm_unlink(shm_name_z.ptr);
            return ShmErr.MmapFailed;
        }

        const ptr: [*]u8 = @ptrFromInt(mapped);
        const hdr: *Header = @ptrCast(@alignCast(ptr));

        if (created) {
            hdr.magic = GLU_MAGIC;
            hdr.write = 0;
            for (&hdr.readers) |*r| r.* = 0;
            hdr.owner_pid = @intCast(std.os.linux.getpid());
            hdr.conns = 1;
            hdr.msg_size = msg_size;
            hdr.capacity = capacity;
            hdr.tos = @intFromEnum(tos);
            const name_len = @min(@as(u32, @intCast(name.len)), 63);
            hdr.name_len = name_len;
            @memcpy(hdr.name[0..name_len], name[0..name_len]);
            hdr.name[name_len] = 0;
        } else {
            // Attaching to a segment we don't own: reject anything that
            // doesn't match the requested geometry instead of reading
            // garbage as a ring buffer.
            if (hdr.magic != GLU_MAGIC or hdr.msg_size != msg_size or hdr.capacity != capacity) {
                _ = os.munmap(ptr, total_size_usize);
                _ = c.close(fd);
                return ShmErr.InvalidSegment;
            }
            _ = @atomicRmw(u32, &hdr.conns, .Add, 1, .acq_rel);
        }

        return .{ .fd = fd, .ptr = ptr, .header = hdr, .size = total_size_usize };
    }

    /// Close this channel handle and unmap the shared memory.
    ///
    /// The underlying POSIX shm is unlinked only when the last connection
    /// is closed (reference counting via `conns`).
    pub fn close(self: *Channel) void {
        assert(self.fd != -1);
        const prev = @atomicRmw(u32, &self.header.conns, .Sub, 1, .acq_rel);

        const needs_unlink = prev == 1;
        var name_buf: [256]u8 = undefined;
        const name_z: ?[:0]u8 = if (needs_unlink) blk: {
            const name_slice = self.header.name[0..self.header.name_len];
            break :blk shm_name(&name_buf, name_slice) orelse null;
        } else null;

        _ = os.munmap(self.ptr, self.size);
        _ = os.close(self.fd);
        self.fd = -1;

        if (name_z) |nz| _ = c.shm_unlink(nz.ptr);
    }

    pub const deinit = close;
};

/// Force-unlink the shared memory segment backing topic `name`.
///
/// Used to reclaim a segment left behind by a crashed publisher whose
/// `conns` refcount could never be decremented, so the file would
/// otherwise leak in `/dev/shm` forever.
pub fn force_unlink(name: []const u8) void {
    var shm_name_buf: [256:0]u8 = undefined;
    if (shm_name(&shm_name_buf, name)) |nz| {
        _ = c.shm_unlink(nz.ptr);
    }
}

/// Write a message into the ring buffer.
///
/// Uses `chan.header.msg_size` so a single entry point serves both Zig
/// and C callers without type-level polymorphism.
/// Blocks with a spin-loop if the buffer is full (slowest-reader
/// backpressure).
pub fn write(chan: *Channel, msg: *const anyopaque) void {
    assert(chan.fd != -1);
    const cap = chan.header.capacity;
    const tos: ToS = @enumFromInt(chan.header.tos);

    while (chan.header.write -% slowest_reader(&chan.header.readers, chan.header.write) >= cap) {
        sweep_dead_readers(&chan.header.readers);
        if (tos == .best_effort) break;
        if (chan.header.write -% slowest_reader(&chan.header.readers, chan.header.write) < cap) break;
        std.atomic.spinLoopHint();
    }

    const msg_size = chan.header.msg_size;
    const slot = chan.ptr + @sizeOf(Header) + (chan.header.write % cap) * msg_size;
    @memcpy(slot, @as([*]const u8, @ptrCast(msg))[0..msg_size]);

    // Publish the slot: make data visible to readers before advancing the cursor.
    _ = @atomicRmw(u32, &chan.header.write, .Add, 1, .release);
}

/// Search for Dead Readers and inactive them.
///
/// Each reader entry packs the owning PID in its high 32 bits. When that
/// PID no longer corresponds to a live process the whole entry is cleared
/// (back to zero), so the slot is unclaimed again and its cursor is
/// ignored when we check for the slowest reader in the reliable
/// connection mode of node communications.
///
/// The clear uses a compare-and-swap against the observed value so a slot
/// that was just reclaimed by a new subscriber in the meantime is never
/// clobbered.
pub fn sweep_dead_readers(readers: *[MAX_READERS]u64) void {
    for (readers) |*entry| {
        const pid: u32 = @intCast(entry.* >> 32);
        if (pid != 0 and !is_alive(pid)) {
            _ = @cmpxchgWeak(u64, entry, entry.*, 0, .acq_rel, .acquire);
        }
    }
}

/// Returns the slowest (smallest) active read cursor.
///
/// Inactive readers (those with a zero entry) are skipped so they don't
/// block the writer. If no readers are active the write cursor itself is
/// returned, meaning the writer will never be held back.
pub fn slowest_reader(readers: []const u64, write_cursor: u32) u32 {
    var min = write_cursor;
    for (readers) |entry| {
        if (entry == 0) continue;
        const cursor: u32 = @truncate(entry);
        min = @min(min, cursor);
    }
    return min;
}

/// Advance the read cursor for `sub_id` and return a pointer to the slot.
///
/// Each subscriber owns one slot in the `readers` array and their cursor
/// is advanced atomically. Slots are reused once all subscribers have
/// read or dropped them.
pub fn read(chan: *Channel, sub_id: u32) *anyopaque {
    assert(chan.fd != -1);
    assert(sub_id < MAX_READERS);
    const msg_size = chan.header.msg_size;
    const cursor = bump_cursor(&chan.header.readers[sub_id]);
    const idx = cursor % chan.header.capacity;
    const slot = chan.ptr + @sizeOf(Header) + idx * msg_size;
    return @ptrCast(slot);
}

/// Return a pointer to the next unread slot for `sub_id` without
/// advancing the read cursor.
///
/// The slot remains readable until the caller acknowledges it with
/// `ack`; the publisher only reuses a slot once every reader has
/// advanced past it. This makes the consume phase safe against the
/// publisher wrapping around mid-read.
pub fn peek(chan: *Channel, sub_id: u32) *anyopaque {
    assert(chan.fd != -1);
    assert(sub_id < MAX_READERS);
    const msg_size = chan.header.msg_size;
    const entry = @atomicLoad(u64, &chan.header.readers[sub_id], .acquire);
    const cursor: u32 = @truncate(entry);
    const idx = cursor % chan.header.capacity;
    const slot = chan.ptr + @sizeOf(Header) + idx * msg_size;
    return @ptrCast(slot);
}

/// Advance the read cursor for `sub_id` after the message returned by
/// `peek` has been consumed.
///
/// The release store publishes the consumed state so the publisher can
/// safely reuse the slot.
pub fn ack(chan: *Channel, sub_id: u32) void {
    assert(chan.fd != -1);
    assert(sub_id < MAX_READERS);
    _ = bump_cursor(&chan.header.readers[sub_id]);
}

/// Atomically advance the low 32-bit cursor of a reader entry, leaving the
/// owning PID in the high 32 bits untouched. Returns the cursor before the
/// advance. A compare-and-swap loop keeps the cursor increment from
/// carrying into the PID field when it wraps.
fn bump_cursor(entry: *u64) u32 {
    while (true) {
        const cur = @atomicLoad(u64, entry, .monotonic);
        const cursor: u32 = @truncate(cur);
        const next = (cur & ~@as(u64, std.math.maxInt(u32))) | @as(u64, cursor +% 1);
        if (@cmpxchgWeak(u64, entry, cur, next, .acq_rel, .monotonic) == null) return cursor;
    }
}

fn reader_entry(pid: u32, cursor: u32) u64 {
    return (@as(u64, pid) << 32) | cursor;
}

test "slowest_reader: skips inactive (zero) readers" {
    const readers = [_]u64{
        reader_entry(100, 5),  0, reader_entry(200, 3), 0,
        reader_entry(300, 10), 0, 0,                    0,
    };
    try std.testing.expectEqual(@as(u32, 3), slowest_reader(&readers, 100));
}

test "slowest_reader: returns write cursor when no active readers" {
    const readers: [MAX_READERS]u64 = std.mem.zeroes([MAX_READERS]u64);
    try std.testing.expectEqual(@as(u32, 42), slowest_reader(&readers, 42));
}

test "slowest_reader: active reader lower than write cursor is selected" {
    const readers = [_]u64{ 0, reader_entry(100, 2), 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(u32, 2), slowest_reader(&readers, 10));
}

test "sweep_dead_readers: reclaims slots of dead PIDs" {
    const my_pid: u32 = @intCast(std.os.linux.getpid());
    var readers = [_]u64{
        reader_entry(my_pid, 10),
        0,
        reader_entry(999999999, 40),
        reader_entry(my_pid, 50),
        0,
        0,
        0,
        0,
    };

    sweep_dead_readers(&readers);

    try std.testing.expectEqual(reader_entry(my_pid, 10), readers[0]);
    try std.testing.expectEqual(@as(u64, 0), readers[1]);
    try std.testing.expectEqual(@as(u64, 0), readers[2]);
    try std.testing.expectEqual(reader_entry(my_pid, 50), readers[3]);
    try std.testing.expectEqual(@as(u64, 0), readers[4]);
}

test "sweep_dead_readers: no crash when all entries are zero" {
    var readers: [MAX_READERS]u64 = std.mem.zeroes([MAX_READERS]u64);

    sweep_dead_readers(&readers);

    for (&readers) |r| try std.testing.expectEqual(@as(u64, 0), r);
}

test "writer not blocked when no active readers" {
    const TestMsg = packed struct { x: u32, y: u32 };

    _ = c.shm_unlink("/glu_test_nowriterblock");

    var chan = try Channel.open("/glu_test_nowriterblock", @sizeOf(TestMsg), 2, .reliable);
    defer chan.close();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open("/glu_test_nowriterblock", @sizeOf(TestMsg), 2, .reliable) catch c.exit(1);
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

    _ = c.shm_unlink("/glu_test_two_readers");

    var chan = try Channel.open("/glu_test_two_readers", @sizeOf(TestMsg), 8, .reliable);
    defer chan.close();

    @atomicStore(u64, &chan.header.readers[0], reader_entry(@intCast(std.os.linux.getpid()), 0), .release);

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open("/glu_test_two_readers", @sizeOf(TestMsg), 8, .reliable) catch c.exit(1);
        @atomicStore(u64, &child_chan.header.readers[1], reader_entry(@intCast(std.os.linux.getpid()), 0), .release);

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

    _ = c.shm_unlink("/glu_test_fork");

    var chan = try Channel.open("/glu_test_fork", @sizeOf(TestMsg), 5, .reliable);
    defer chan.close();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Channel.open("/glu_test_fork", @sizeOf(TestMsg), 5, .reliable) catch c.exit(1);
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

test "Channel.open rejects an existing segment with mismatched geometry" {
    const TestMsg = packed struct { x: u32 };

    _ = c.shm_unlink("/glu_test_mismatch_attach");

    var base = try Channel.open("/glu_test_mismatch_attach", @sizeOf(TestMsg), 8, .reliable);
    defer base.close();

    try std.testing.expectError(error.InvalidSegment, Channel.open("/glu_test_mismatch_attach", @sizeOf(TestMsg) + 4, 8, .reliable));
    try std.testing.expectError(error.InvalidSegment, Channel.open("/glu_test_mismatch_attach", @sizeOf(TestMsg), 16, .reliable));

    var ok = try Channel.open("/glu_test_mismatch_attach", @sizeOf(TestMsg), 8, .reliable);
    ok.close();
}

test "Channel.open rejects configurations whose data region overflows" {
    _ = c.shm_unlink("/glu_test_overflow");

    // (2^32-1)^2 wraps a u32 product (to 1); must be rejected up front.
    try std.testing.expectError(error.InvalidSegment, Channel.open("/glu_test_overflow", std.math.maxInt(u32), std.math.maxInt(u32), .reliable));

    // No segment should have been created in /dev/shm as a side effect.
    const flags: c_int = @as(c_int, @bitCast(os.O{ .ACCMODE = .RDONLY }));
    try std.testing.expectEqual(@as(c_int, -1), c.shm_open("/glu_test_overflow", flags, 0));
}
