const std = @import("std");
const c = std.c;
const os = std.os.linux;

const GLU_MAGIC = @import("../channel.zig").GLU_MAGIC;
const Header = @import("../channel.zig").Header;

/// Scan `/dev/shm` for glu topics and unlink them all.
///
/// Called on shutdown to clean up stale shared memory segments
/// that may remain after a crash.
pub fn cleanupTopics() void {
    const dirp = c.opendir("/dev/shm") orelse return;
    defer _ = c.closedir(dirp);

    while (true) {
        const entry = c.readdir(dirp) orelse break;
        if (entry.type != 8) continue;
        const name = std.mem.sliceTo(@as([]const u8, entry.name[0..]), 0);
        if (name.len == 0) continue;
        if (std.mem.startsWith(u8, name, "sem.")) continue;

        var shm_name_buf: [256]u8 = undefined;
        const shm_name = std.fmt.bufPrint(&shm_name_buf, "/{s}", .{name}) catch continue;
        shm_name_buf[shm_name.len] = 0;

        const fd = c.shm_open(shm_name_buf[0..shm_name.len :0], 0, 0);
        if (fd == -1) continue;
        defer _ = c.close(fd);

        const mapped = os.mmap(null, @sizeOf(Header), os.PROT{ .READ = true }, os.MAP{ .TYPE = .SHARED }, fd, 0);
        if (mapped == ~@as(usize, 0)) continue;

        const ptr: [*]u8 = @ptrFromInt(mapped);
        const hdr: *align(1) Header = @ptrCast(ptr);
        const is_glu = hdr.magic == GLU_MAGIC;
        _ = os.munmap(@ptrFromInt(mapped), @sizeOf(Header));

        if (is_glu) _ = c.shm_unlink(shm_name_buf[0..shm_name.len :0]);
    }
}
