const std = @import("std");
const c = std.c;
const os = std.os.linux;

const Topic = @import("topic.zig").Topic;
const slowest_reader = @import("../channel.zig").slowest_reader;
const MAX_READERS = @import("../channel.zig").MAX_READERS;

pub const ScanErr = error{
    ShmDirInaccessible,
};

/// A summary of an active glu topic, suitable for listing.
pub const TopicEntry = struct {
    name: [64]u8,
    name_len: u32,
    msg_size: u32,
    capacity: u32,
    conns: u32,
    write_pos: u32,
    read_pos: u32,
};

/// Scan `/dev/shm` for active glu topics and return a summary of each.
///
/// Writes up to `entries.len` elements into the provided slice.
/// Returns the number of topics found and written.
/// Returns `error.ShmDirInaccessible` if `/dev/shm` cannot be opened.
pub fn scan_topics(entries: []TopicEntry) ScanErr!usize {
    const dirp = c.opendir("/dev/shm") orelse return error.ShmDirInaccessible;
    defer _ = c.closedir(dirp);

    var count: usize = 0;
    while (count < entries.len) {
        const entry = c.readdir(dirp) orelse break;
        if (entry.type != 8) continue; // DT_REG
        const name = std.mem.sliceTo(@as([]const u8, entry.name[0..]), 0);
        if (name.len == 0) continue;
        if (std.mem.startsWith(u8, name, "sem.")) continue;

        var shm_name_buf: [256]u8 = undefined;
        const shm_name = std.fmt.bufPrint(&shm_name_buf, "/{s}", .{name}) catch continue;

        var topic = Topic.open(shm_name) catch continue;
        defer topic.close();
        const hdr = topic.header;

        var name_arr = std.mem.zeroes([64]u8);
        const name_len = @min(@as(u32, @intCast(hdr.name_len)), 63);
        @memcpy(name_arr[0..name_len], hdr.name[0..name_len]);

        var read_vals: [MAX_READERS]u64 = undefined;
        @memcpy(&read_vals, &hdr.readers);

        entries[count] = .{
            .name = name_arr,
            .name_len = name_len,
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
