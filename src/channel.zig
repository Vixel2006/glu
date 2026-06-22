const std = @import("std");
const c = @import("std").c;
const os = @import("std").os.linux;
const SEEK_END = 2;

pub const GLU_MAGIC = 0x474C5500;

pub const Header = extern struct {
    magic: u32 = GLU_MAGIC,
    write: u32,
    conns: u32,
    msg_size: u32,
    capacity: u32,
    name_len: u32,
    name: [64]u8, // pushes read past cache line boundary
    read: u32,
    _reserved: [4]u8 = .{0} ** 4,
};

comptime {
    std.debug.assert(@sizeOf(Header) == 96);
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
            hdr.write = 0;
            hdr.read = 0;
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

pub fn reserve(chan: *Channel, comptime T: type) *T {
    while (chan.header.write -% @atomicLoad(u32, &chan.header.read, .acquire) >= chan.header.capacity) std.atomic.spinLoopHint();
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
    while (chan.header.write -% @atomicLoad(u32, &chan.header.read, .acquire) >= cap) std.atomic.spinLoopHint();

    const msg_size = chan.header.msg_size;
    const slot = chan.ptr + @sizeOf(Header) + (chan.header.write % cap) * msg_size;
    @memcpy(slot, @as(*const [@sizeOf(T)]u8, @ptrCast(msg)));
}

pub fn read(chan: *Channel, comptime T: type) *T {
    const msg_size = chan.header.msg_size;
    const idx = @atomicRmw(u32, &chan.header.read, .Add, 1, .acquire) % chan.header.capacity;
    const slot = chan.ptr + @sizeOf(Header) + idx * msg_size;
    return @ptrCast(@alignCast(slot));
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
    const msg = read(&chan, TestMsg);
    try std.testing.expect(msg.x == 42);
    try std.testing.expect(msg.y == 99);

    _ = c.waitpid(pid, null, 0);
}
