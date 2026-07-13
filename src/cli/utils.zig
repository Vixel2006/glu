const std = @import("std");
const assert = std.debug.assert;
const c = @import("std").c;
const os = @import("std").os.linux;

pub const GLU_MAGIC = @import("../channel.zig").GLU_MAGIC;
pub const Header = @import("../channel.zig").Header;

const TopicErr = error{
    OutOfMemory,
    TopicNotFound,
    InvalidTopic,
    MmapFailed,
    BadMagic,
};

pub fn logErr(comptime ctx: []const u8, err: anyerror) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var fw = std.Io.File.stderr().writerStreaming(io, &.{});
    const w = &fw.interface;
    w.print("error: {s}: {s}\n", .{ ctx, @errorName(err) }) catch {};
    if (@errorReturnTrace()) |trace| {
        const cast: *const std.debug.StackTrace = @ptrCast(trace);
        std.debug.dumpStackTrace(cast);
    }
}

pub fn writer(init: std.process.Init) std.Io.File.Writer {
    return std.Io.File.stdout().writerStreaming(init.io, &.{});
}

pub fn errWriter(init: std.process.Init) std.Io.File.Writer {
    return std.Io.File.stderr().writerStreaming(init.io, &.{});
}

/// A read-only handle to an existing shared memory topic.
///
/// Used by CLI commands (`list`, `info`) to inspect live channels
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
        const name_z = try allocator.dupeZ(u8, name);
        defer allocator.free(name_z);

        const fd = c.shm_open(name_z.ptr, @as(c_int, @bitCast(os.O{ .ACCMODE = .RDWR })), 0);
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
