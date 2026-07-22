const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const os = std.os.linux;

const GLU_MAGIC = @import("../channel.zig").GLU_MAGIC;
const Header = @import("../channel.zig").Header;

pub const TopicErr = error{
    OutOfMemory,
    TopicNotFound,
    InvalidTopic,
    MmapFailed,
    BadMagic,
};

/// A read-only handle to an existing shared memory topic.
///
/// Used by CLI commands and debug tools to inspect live channels
/// without participating as a publisher or subscriber.
pub const Topic = struct {
    fd: i32,
    mapped: usize,
    header: *align(1) Header,
    file_size: usize,

    /// Open an existing topic for read-only inspection.
    ///
    /// Validates the magic number to ensure it's a glu channel.
    pub fn open(allocator: std.mem.Allocator, name: []const u8) TopicErr!Topic {
        assert(name.len > 0);
        const name_z = try allocator.alloc(u8, name.len + 1);
        defer allocator.free(name_z);
        @memcpy(name_z[0..name.len], name);
        name_z[name.len] = 0;

        const fd = c.shm_open(name_z[0..name.len :0], @as(c_int, @bitCast(os.O{ .ACCMODE = .RDWR })), 0);
        if (fd == -1) return error.TopicNotFound;
        errdefer _ = os.close(fd);

        const file_size = @as(usize, @intCast(c.lseek(fd, 0, 2)));
        if (file_size < @sizeOf(Header)) return error.InvalidTopic;

        const mapped = os.mmap(null, file_size, os.PROT{ .READ = true }, os.MAP{ .TYPE = .SHARED }, fd, 0);
        if (mapped == ~@as(usize, 0)) return error.MmapFailed;
        errdefer _ = os.munmap(@ptrFromInt(mapped), file_size);

        const ptr: [*]u8 = @ptrFromInt(mapped);
        const hdr: *align(1) Header = @ptrCast(ptr);
        if (hdr.magic != GLU_MAGIC) return error.BadMagic;

        return .{ .fd = fd, .mapped = mapped, .header = hdr, .file_size = file_size };
    }

    pub fn close(self: *Topic) void {
        assert(self.fd != -1);
        _ = os.munmap(@ptrFromInt(self.mapped), self.file_size);
        _ = os.close(self.fd);
        self.fd = -1;
    }
};
