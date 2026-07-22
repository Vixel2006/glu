const std = @import("std");
const c = std.c;
const os = std.os.linux;

const Topic = @import("topic.zig").Topic;
const slowestReader = @import("../channel.zig").slowestReader;
const MAX_READERS = @import("../channel.zig").MAX_READERS;

pub const ScanErr = error{
    OutOfMemory,
    ShmDirInaccessible,
};

/// A summary of an active glu topic, suitable for listing.
pub const TopicEntry = struct {
    name: []const u8,
    msg_size: u32,
    capacity: u32,
    conns: u32,
    write_pos: u32,
    read_pos: u32,

    pub fn deinit(self: *TopicEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Scan `/dev/shm` for active glu topics and return a summary of each.
///
/// Returns an owned slice allocated with `allocator`. Each entry's
/// `name` is also allocator-owned and must be freed individually.
/// Returns `error.ShmDirInaccessible` if `/dev/shm` cannot be opened.
pub fn scanTopics(allocator: std.mem.Allocator) ScanErr![]TopicEntry {
    var entries = std.ArrayList(TopicEntry).empty;
    errdefer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit(allocator);
    }

    const dirp = c.opendir("/dev/shm") orelse return error.ShmDirInaccessible;
    defer _ = c.closedir(dirp);

    while (true) {
        const entry = c.readdir(dirp) orelse break;
        if (entry.type != 8) continue; // DT_REG
        const name = std.mem.sliceTo(@as([]const u8, entry.name[0..]), 0);
        if (name.len == 0) continue;
        if (std.mem.startsWith(u8, name, "sem.")) continue;

        var shm_name_buf: [256]u8 = undefined;
        const shm_name = std.fmt.bufPrint(&shm_name_buf, "/{s}", .{name}) catch continue;

        var topic = Topic.open(allocator, shm_name) catch continue;
        defer topic.close();
        const hdr = topic.header;

        const name_copy = try allocator.dupe(u8, hdr.name[0..hdr.name_len]);
        errdefer allocator.free(name_copy);

        var read_vals: [MAX_READERS]u32 = undefined;
        @memcpy(&read_vals, &hdr.read);

        try entries.append(allocator, .{
            .name = name_copy,
            .msg_size = hdr.msg_size,
            .capacity = hdr.capacity,
            .conns = hdr.conns,
            .write_pos = hdr.write,
            .read_pos = slowestReader(&read_vals, hdr.write),
        });
    }

    return entries.toOwnedSlice(allocator);
}
