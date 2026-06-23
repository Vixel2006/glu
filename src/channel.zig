const std = @import("std");
const c = @import("std").c;
const os = @import("std").os.linux;
const SEEK_END = 2;

pub const GLU_MAGIC = 0x474C5500;
pub const MAX_READERS = 8;

pub const Header = extern struct {
    magic: u32 = GLU_MAGIC,
    write: u32,
    conns: u32,
    msg_size: u32,
    capacity: u32,
    name_len: u32,
    name: [64]u8, // pushes read past cache line boundary
    read: [MAX_READERS]u32,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 120);
}

pub const Channel = struct {
    fd: i32,
    ptr: [*]u8,
    header: *Header,
    size: usize,

    pub fn open(allocator: std.mem.Allocator, name: []const u8, msg_size: u32, capacity: u32) !Channel {
        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);

        const o_flags: c_int = @as(c_int, @bitCast(os.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }));

        var fd: i32 = c.shm_open(name_z.ptr, o_flags, 0o644);
        var created = true;

        if (fd == -1) {
            const open_flags: c_int = @as(c_int, @bitCast(os.O{
                .ACCMODE = .RDWR,
            }));
            fd = c.shm_open(name_z.ptr, open_flags, 0);
            created = false;
        }

        if (fd == -1) return error.ShmOpenFailed;

        const data_size = msg_size * capacity;
        const total_size: usize = data_size + @sizeOf(Header);
        const map_size: usize = total_size;

        if (created) {
            _ = c.ftruncate(fd, @intCast(total_size));
        } else {
            const current_size = @as(usize, @intCast(c.lseek(fd, 0, SEEK_END)));
            if (current_size < total_size) {
                _ = c.ftruncate(fd, @intCast(total_size));
            }
        }

        const mapped = os.mmap(
            null,
            map_size,
            os.PROT{ .READ = true, .WRITE = true },
            os.MAP{ .TYPE = .SHARED },
            fd,
            0,
        );

        if (mapped == ~@as(usize, 0)) return error.MmapFailed;

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
            _ = @atomicRmw(u32, &hdr.conns, .Add, 1, .monotonic);
        }

        return .{ .fd = fd, .ptr = ptr, .header = hdr, .size = map_size };
    }

    pub fn close(self: *Channel) void {
        const prev = @atomicRmw(u32, &self.header.conns, .Sub, 1, .monotonic);

        const needs_unlink = prev == 1;
        var name_buf: [256]u8 = undefined;
        const name_z: ?[:0]u8 = if (needs_unlink) blk: {
            const name_slice = self.header.name[0..self.header.name_len];
            break :blk std.fmt.bufPrintZ(&name_buf, "{s}", .{name_slice}) catch null;
        } else null;

        _ = os.munmap(self.ptr, self.size);
        _ = os.close(self.fd);

        if (name_z) |nz| _ = c.shm_unlink(nz.ptr);
    }
};

pub fn slowestReader(readers: []const u32, write_cursor: u32) u32 {
    var min = write_cursor;
    for (readers) |reader| {
        if (reader != std.math.maxInt(u32)) {
            min = @min(min, reader);
        }
    }
    return min;
}

pub fn reserve(chan: *Channel, comptime T: type) *T {
    while (chan.header.write -% slowestReader(&chan.header.read, chan.header.write) >= chan.header.capacity) std.atomic.spinLoopHint();
    const slot = chan.ptr + @sizeOf(Header) + (chan.header.write % chan.header.capacity) * chan.header.msg_size;
    return @ptrCast(@alignCast(slot));
}

pub fn commit(chan: *Channel) void {
    @atomicStore(u32, &chan.header.write, chan.header.write + 1, .release);
}

/// We are sure to have only one publisher for the channel so we can use the write chan without atomic
/// this can make the write faster
pub fn write(chan: *Channel, comptime T: type, msg: *const T) void {
    defer @atomicStore(u32, &chan.header.write, chan.header.write + 1, .release);

    const cap = chan.header.capacity;

    // Check if the write trying to write on an un-read slot and stop it until the reader catch up
    while (chan.header.write -% slowestReader(&chan.header.read, chan.header.write) >= cap) std.atomic.spinLoopHint();

    const msg_size = chan.header.msg_size;
    const slot = chan.ptr + @sizeOf(Header) + (chan.header.write % cap) * msg_size;
    @memcpy(slot, @as(*const [@sizeOf(T)]u8, @ptrCast(msg)));
}

pub fn read(chan: *Channel, comptime T: type, sub_id: u32) *T {
    const msg_size = chan.header.msg_size;
    const idx = @atomicRmw(u32, &chan.header.read[sub_id], .Add, 1, .acquire) % chan.header.capacity;
    const slot = chan.ptr + @sizeOf(Header) + idx * msg_size;
    return @ptrCast(@alignCast(slot));
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
        write(&child_chan, TestMsg, &.{ .x = 1, .y = 1 });
        write(&child_chan, TestMsg, &.{ .x = 2, .y = 2 });
        write(&child_chan, TestMsg, &.{ .x = 3, .y = 3 });
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

        const m0 = read(&child_chan, TestMsg, 1);
        const m1 = read(&child_chan, TestMsg, 1);
        if (m0.x != 10 or m0.y != 20) c.exit(1);
        if (m1.x != 30 or m1.y != 40) c.exit(1);

        child_chan.close();
        c.exit(0);
    }

    write(&chan, TestMsg, &.{ .x = 10, .y = 20 });
    write(&chan, TestMsg, &.{ .x = 30, .y = 40 });

    {
        var ts = std.c.timespec{ .sec = 0, .nsec = 50_000_000 };
        _ = c.nanosleep(&ts, null);
    }

    const m0 = read(&chan, TestMsg, 0);
    try std.testing.expect(m0.x == 10);
    try std.testing.expect(m0.y == 20);
    const m1 = read(&chan, TestMsg, 0);
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
        write(&child_chan, TestMsg, &TestMsg{ .x = 42, .y = 99 });
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
