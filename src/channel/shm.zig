const std = @import("std");
const assert = std.debug.assert;
const c = @import("std").c;
const os = @import("std").os.linux;

const is_alive = @import("../registry.zig").is_alive;
const constants = @import("../constants.zig");

pub const ShmErr = error{ OutOfMemory, ShmOpenFailed, MmapFailed, InvalidSegment };

pub fn shm_name(buf: []u8, name: []const u8) ?[:0]u8 {
    if (name.len >= buf.len) return null;
    for (name, 0..) |ch, i| {
        buf[i] = if (i > 0 and ch == '/') '_' else ch;
    }
    buf[name.len] = 0;
    return buf[0..name.len :0];
}

pub fn validate_header(
    hdr: *align(1) const Header,
    expected: ?struct { msg_size: u32, capacity: u32 },
    file_size: ?usize,
) bool {
    if (hdr.magic != constants.GLU_MAGIC) return false;
    if (hdr.msg_size == 0 or hdr.msg_size > constants.MAX_MSG_SIZE) return false;
    if (hdr.capacity == 0 or hdr.capacity > constants.MAX_CAPACITY) return false;
    if (hdr.name_len > constants.MAX_NAME_LEN) return false;
    if (hdr.name_len > 0 and hdr.name[hdr.name_len] != 0) return false;
    if (hdr.tos != @intFromEnum(ToS.reliable) and hdr.tos != @intFromEnum(ToS.best_effort))
        return false;

    if (expected) |geo| {
        if (hdr.msg_size != geo.msg_size or hdr.capacity != geo.capacity) return false;
    }

    // The total mapped size must fit in the offset type used by ftruncate
    // and must fit inside the actual file, otherwise reads past EOF fail
    // with SIGBUS instead of a clean error.
    const data_size = hdr.msg_size *| hdr.capacity;
    const total_size = data_size +| @sizeOf(Header);
    if (file_size) |fs| {
        if (fs < total_size) return false;
    }
    return true;
}

/// Type of Service for channel delivery semantics.
pub const ToS = enum(u32) {
    reliable = 0,
    best_effort = 1,
};

pub const Header = extern struct {
    magic: u32 = constants.GLU_MAGIC,
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
    readers: [constants.MAX_READERS]u64,
};

pub const Shm = struct {
    fd: i32,
    ptr: [*]u8,
    header: *Header,
    size: usize,
    cap: u32,
    msg_size: u32,
    tos: ToS,

    pub fn open(name: []const u8, msg_size: u32, capacity: u32, tos: ToS) ShmErr!Shm {
        assert(msg_size > 0);
        assert(capacity > 0);
        assert(name.len > 0);

        const data_size = msg_size *| capacity;
        const size: usize = @as(u32, @intCast(data_size +| @sizeOf(Header)));

        var name_buf: [256:0]u8 = undefined;
        const shm_z = shm_name(&name_buf, name) orelse return ShmErr.ShmOpenFailed;

        var created = true;
        var fd = c.shm_open(shm_z.ptr, @bitCast(os.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }), 0o600);
        if (fd == -1) {
            fd = c.shm_open(shm_z.ptr, @bitCast(os.O{ .ACCMODE = .RDWR }), 0);
            created = false;
        }
        if (fd == -1) return ShmErr.ShmOpenFailed;

        errdefer {
            _ = c.close(fd);
            // NOTE: Don't leak a half-created segment in /dev/shm.
            if (created) _ = c.shm_unlink(shm_z.ptr);
        }

        var file_size: usize = size;
        if (created) {
            if (c.ftruncate(fd, @intCast(size)) == -1) return ShmErr.ShmOpenFailed;
        } else {
            // Guard against SIGBUS from mapping beyond EOF.
            const sz = c.lseek(fd, 0, 2);
            if (sz < @sizeOf(Header)) return ShmErr.InvalidSegment;
            file_size = @intCast(sz);
        }

        const mapped = os.mmap(null, size, os.PROT{ .READ = true, .WRITE = true }, os.MAP{ .TYPE = .SHARED }, fd, 0);
        if (mapped == ~@as(usize, 0)) return ShmErr.MmapFailed;

        const ptr: [*]u8 = @ptrFromInt(mapped);
        const hdr: *Header = @ptrCast(@alignCast(ptr));
        errdefer _ = os.munmap(ptr, size);

        if (!created) {
            _ = @atomicRmw(u32, &hdr.conns, .Add, 1, .acq_rel);
            // Reject anything that doesn't match, instead of reading garbage as a ring buffer.
            if (!validate_header(hdr, .{ .msg_size = msg_size, .capacity = capacity }, file_size))
                return ShmErr.InvalidSegment;
        } else {
            const name_len: u32 = @intCast(@min(name.len, 63));
            hdr.* = std.mem.zeroInit(Header, .{
                .magic = constants.GLU_MAGIC,
                .conns = 1,
                .msg_size = msg_size,
                .capacity = capacity,
                .tos = @intFromEnum(tos),
                .owner_pid = @as(u32, @intCast(std.os.linux.getpid())),
                .name_len = name_len,
            });
            @memcpy(hdr.name[0..name_len], name[0..name_len]);
        }

        return .{ .fd = fd, .ptr = ptr, .header = hdr, .size = size, .cap = capacity, .msg_size = msg_size, .tos = tos };
    }

    pub fn close(self: *Shm) void {
        assert(self.fd != -1);
        const prev = @atomicRmw(u32, &self.header.conns, .Sub, 1, .acq_rel);

        var name_buf: [256]u8 = undefined;
        const name_z: ?[:0]u8 = if (prev == 1) blk: {
            // The header lives in shared memory and could have been tampered
            // with since open; clamp the length before slicing `name`.
            const name_len = @min(self.header.name_len, constants.MAX_NAME_LEN);
            const name_slice = self.header.name[0..name_len];
            break :blk shm_name(&name_buf, name_slice) orelse null;
        } else null;

        _ = os.munmap(self.ptr, self.size);
        _ = os.close(self.fd);
        self.fd = -1;

        if (name_z) |nz| _ = c.shm_unlink(nz.ptr);
    }

    pub const deinit = close;

    pub fn write(self: *Shm, msg: *const anyopaque) void {
        assert(self.fd != -1);
        const cap = self.cap;
        const tos = self.tos;

        if (tos == .reliable) {
            while (self.header.write -% slowest_reader(&self.header.readers, self.header.write) >= cap) {
                sweep_dead_readers(&self.header.readers);
                if (self.header.write -% slowest_reader(&self.header.readers, self.header.write) < cap) break;
                std.atomic.spinLoopHint();
            }
        }

        const msg_size = self.msg_size;
        const slot = self.ptr + @sizeOf(Header) + (self.header.write % cap) * msg_size;
        @memcpy(slot, @as([*]const u8, @ptrCast(msg))[0..msg_size]);

        // Publish the slot: make data visible to readers before advancing the cursor.
        _ = @atomicRmw(u32, &self.header.write, .Add, 1, .release);
    }

    pub fn peek(self: *Shm, sub_id: u32) *anyopaque {
        assert(self.fd != -1);
        assert(sub_id < constants.MAX_READERS);
        const msg_size = self.msg_size;
        const entry = @atomicLoad(u64, &self.header.readers[sub_id], .acquire);
        const cursor: u32 = @truncate(entry);
        const idx = cursor % self.cap;
        const slot = self.ptr + @sizeOf(Header) + idx * msg_size;
        return @ptrCast(slot);
    }

    pub fn ack(self: *Shm, sub_id: u32) void {
        assert(self.fd != -1);
        assert(sub_id < constants.MAX_READERS);

        const entry = &self.header.readers[sub_id];
        while (true) {
            const cur = @atomicLoad(u64, entry, .monotonic);
            const cursor: u32 = @truncate(cur);
            const next = (cur & ~@as(u64, std.math.maxInt(u32))) | @as(u64, cursor +% 1);
            if (@cmpxchgWeak(u64, entry, cur, next, .acq_rel, .monotonic) == null) return;
        }
    }
};

pub fn force_unlink(name: []const u8) void {
    var shm_name_buf: [256:0]u8 = undefined;
    if (shm_name(&shm_name_buf, name)) |nz| {
        _ = c.shm_unlink(nz.ptr);
    }
}

pub fn sweep_dead_readers(readers: *[constants.MAX_READERS]u64) void {
    for (readers) |*entry| {
        const pid: u32 = @intCast(entry.* >> 32);
        if (pid != 0 and !is_alive(pid)) {
            _ = @cmpxchgWeak(u64, entry, entry.*, 0, .acq_rel, .acquire);
        }
    }
}

pub fn slowest_reader(readers: []align(1) const u64, write_cursor: u32) u32 {
    var min = write_cursor;
    for (readers) |entry| {
        if (entry == 0) continue;
        const cursor: u32 = @truncate(entry);
        min = @min(min, cursor);
    }
    return min;
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
    const readers: [constants.MAX_READERS]u64 = std.mem.zeroes([constants.MAX_READERS]u64);
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
    var readers: [constants.MAX_READERS]u64 = std.mem.zeroes([constants.MAX_READERS]u64);

    sweep_dead_readers(&readers);

    for (&readers) |r| try std.testing.expectEqual(@as(u64, 0), r);
}

test "writer not blocked when no active readers" {
    const TestMsg = packed struct { x: u32, y: u32 };

    _ = c.shm_unlink("/glu_test_nowriterblock");

    var chan = try Shm.open("/glu_test_nowriterblock", @sizeOf(TestMsg), 2, .reliable);
    defer chan.close();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Shm.open("/glu_test_nowriterblock", @sizeOf(TestMsg), 2, .reliable) catch c.exit(1);
        child_chan.write(@ptrCast(&TestMsg{ .x = 1, .y = 1 }));
        child_chan.write(@ptrCast(&TestMsg{ .x = 2, .y = 2 }));
        child_chan.write(@ptrCast(&TestMsg{ .x = 3, .y = 3 }));
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

    var chan = try Shm.open("/glu_test_two_readers", @sizeOf(TestMsg), 8, .reliable);
    defer chan.close();

    @atomicStore(u64, &chan.header.readers[0], reader_entry(@intCast(std.os.linux.getpid()), 0), .release);

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Shm.open("/glu_test_two_readers", @sizeOf(TestMsg), 8, .reliable) catch c.exit(1);
        @atomicStore(u64, &child_chan.header.readers[1], reader_entry(@intCast(std.os.linux.getpid()), 0), .release);

        {
            var ts = std.c.timespec{ .sec = 0, .nsec = 50_000_000 };
            _ = c.nanosleep(&ts, null);
        }

        const m0: *const TestMsg = @ptrCast(@alignCast(child_chan.peek(1)));
        child_chan.ack(1);
        const m1: *const TestMsg = @ptrCast(@alignCast(child_chan.peek(1)));
        child_chan.ack(1);
        if (m0.x != 10 or m0.y != 20) c.exit(1);
        if (m1.x != 30 or m1.y != 40) c.exit(1);

        child_chan.close();
        c.exit(0);
    }

    chan.write(@ptrCast(&TestMsg{ .x = 10, .y = 20 }));
    chan.write(@ptrCast(&TestMsg{ .x = 30, .y = 40 }));

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 50_000_000 };
        _ = c.nanosleep(&ts, null);
    }

    const m0: *const TestMsg = @ptrCast(@alignCast(chan.peek(0)));
    try std.testing.expect(m0.x == 10);
    try std.testing.expect(m0.y == 20);
    chan.ack(0);
    const m1: *const TestMsg = @ptrCast(@alignCast(chan.peek(0)));
    try std.testing.expect(m1.x == 30);
    try std.testing.expect(m1.y == 40);
    chan.ack(0);

    _ = c.waitpid(pid, null, 0);
}

test "cross-process: producer writes, consumer reads via fork" {
    const TestMsg = packed struct { x: u32, y: u32 };

    _ = c.shm_unlink("/glu_test_fork");

    var chan = try Shm.open("/glu_test_fork", @sizeOf(TestMsg), 5, .reliable);
    defer chan.close();

    const pid = c.fork();
    if (pid == 0) {
        var child_chan = Shm.open("/glu_test_fork", @sizeOf(TestMsg), 5, .reliable) catch c.exit(1);
        child_chan.write(@ptrCast(&TestMsg{ .x = 42, .y = 99 }));
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

test "Shm.open rejects an existing segment with mismatched geometry" {
    const TestMsg = packed struct { x: u32 };

    _ = c.shm_unlink("/glu_test_mismatch_attach");

    var base = try Shm.open("/glu_test_mismatch_attach", @sizeOf(TestMsg), 8, .reliable);
    defer base.close();

    try std.testing.expectError(error.InvalidSegment, Shm.open("/glu_test_mismatch_attach", @sizeOf(TestMsg) + 4, 8, .reliable));
    try std.testing.expectError(error.InvalidSegment, Shm.open("/glu_test_mismatch_attach", @sizeOf(TestMsg), 16, .reliable));

    var ok = try Shm.open("/glu_test_mismatch_attach", @sizeOf(TestMsg), 8, .reliable);
    ok.close();
}
