const std = @import("std");
const c = std.c;
const os = std.os.linux;

const Topic = @import("topic.zig").Topic;
const slowest_reader = @import("../channel.zig").slowest_reader;
const MAX_READERS = @import("../channel.zig").MAX_READERS;

pub const ScanErr = error{
    ShmDirInaccessible,
};

/// Iterates `/dev/shm`, yielding the bare name of each regular file that is
/// not a POSIX semaphore (`sem.*`).
pub const ShmScanner = struct {
    dirp: *c.DIR,

    pub fn init() ScanErr!ShmScanner {
        const dirp = c.opendir("/dev/shm") orelse return error.ShmDirInaccessible;
        return .{ .dirp = dirp };
    }

    pub fn deinit(self: *ShmScanner) void {
        _ = c.closedir(self.dirp);
    }

    pub fn next(self: *ShmScanner) ?[]const u8 {
        while (true) {
            const entry = c.readdir(self.dirp) orelse return null;
            if (entry.type != 8) continue; // DT_REG
            const name = std.mem.sliceTo(@as([]const u8, entry.name[0..]), 0);
            if (name.len == 0) continue;
            if (std.mem.startsWith(u8, name, "sem.")) continue;
            return name;
        }
    }
};

/// A summary of an active glu topic, for listing (`glu list`) and
/// correlation with its owning node (`glu status`).
pub const TopicEntry = struct {
    name: [64]u8,
    name_len: u32,
    owner_pid: u32,
    tos: u32,
    msg_size: u32,
    capacity: u32,
    conns: u32,
    write_pos: u32,
    read_pos: u32,
};

/// Scan `/dev/shm` for active glu topics and return a summary of each.
///
/// Writes the `entries.len`-bounded topics into the provided slice and
/// returns how many were found.
pub fn scan_topics(entries: []TopicEntry) ScanErr!usize {
    var scan = try ShmScanner.init();
    defer scan.deinit();

    var count: usize = 0;
    while (count < entries.len) blk: {
        const name = scan.next() orelse break;

        var shm_name_buf: [256]u8 = undefined;
        const shm_name = std.fmt.bufPrint(&shm_name_buf, "/{s}", .{name}) catch continue;

        var topic = Topic.open(shm_name) catch break :blk;
        defer topic.close();
        const hdr = topic.header;

        var name_arr: [64]u8 = undefined;
        const name_len = @min(hdr.name_len, 63);
        @memcpy(name_arr[0..name_len], hdr.name[0..name_len]);

        var read_vals: [MAX_READERS]u64 = undefined;
        @memcpy(&read_vals, &hdr.readers);

        entries[count] = .{
            .name = name_arr,
            .name_len = name_len,
            .owner_pid = hdr.owner_pid,
            .tos = hdr.tos,
            .msg_size = hdr.msg_size,
            .capacity = hdr.capacity,
            .conns = hdr.conns,
            .write_pos = hdr.write,
            .read_pos = slowest_reader(&read_vals, hdr.write),
        };
        count += 1;
    }

    return count;
}
