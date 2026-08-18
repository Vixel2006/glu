const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const os = std.os.linux;

const GLU_MAGIC = @import("../constants.zig").GLU_MAGIC;
const Header = @import("../channel/shm.zig").Header;
const shm_name = @import("../channel/shm.zig").shm_name;
const validate_header = @import("../channel/shm.zig").validate_header;

pub const TopicErr = error{
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
    pub fn open(name: []const u8) TopicErr!Topic {
        assert(name.len > 0);
        var name_buf: [256:0]u8 = undefined;
        const name_z = shm_name(&name_buf, name) orelse return error.InvalidTopic;

        const fd = c.shm_open(name_z.ptr, @as(c_int, @bitCast(os.O{ .ACCMODE = .RDWR })), 0);
        if (fd == -1) return error.TopicNotFound;
        errdefer _ = os.close(fd);

        const file_size = @as(usize, @intCast(c.lseek(fd, 0, @intCast(std.posix.SEEK.END))));
        if (file_size < @sizeOf(Header)) return error.InvalidTopic;

        const mapped = os.mmap(null, file_size, os.PROT{ .READ = true }, os.MAP{ .TYPE = .SHARED }, fd, 0);
        if (mapped == ~@as(usize, 0)) return error.MmapFailed;
        errdefer _ = os.munmap(@ptrFromInt(mapped), file_size);

        const ptr: [*]u8 = @ptrFromInt(mapped);
        const hdr: *align(1) Header = @ptrCast(ptr);
        // Reject anything that isn't a structurally sound glu channel,
        // including segments whose header geometry or name length is
        // inconsistent. Capacity/msg_size of zero would otherwise corrupt
        // the CLI's arithmetic, and a bad name_len an OOB slice.
        if (!validate_header(hdr, null, file_size)) {
            return if (hdr.magic != GLU_MAGIC) error.BadMagic else error.InvalidTopic;
        }

        return .{ .fd = fd, .mapped = mapped, .header = hdr, .file_size = file_size };
    }

    pub fn close(self: *Topic) void {
        assert(self.fd != -1);
        _ = os.munmap(@ptrFromInt(self.mapped), self.file_size);
        _ = os.close(self.fd);
        self.fd = -1;
    }
};
