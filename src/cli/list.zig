const std = @import("std");
const utils = @import("utils.zig");
const topic = @import("../topic/mod.zig");

/// List all active glu topics in shared memory (`glu list` / `glu ls`).
pub fn cmd_list(init: std.process.Init) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    var entry_buf: [128]topic.TopicEntry = undefined;
    const count = topic.scan_topics(&entry_buf) catch |err| switch (err) {
        error.ShmDirInaccessible => {
            try w.writeAll("error: /dev/shm not accessible\n");
            return;
        },
    };

    if (count == 0) {
        try w.writeAll("no active topics\n");
        return;
    }

    try w.writeAll(" Topic                    Size    Cap  Conns  Write  Read  Depth\n");
    try w.writeAll(" ──────────────────────── ─────── ──── ────── ────── ───── ──────\n");
    for (entry_buf[0..count]) |e| {
        const depth = e.write_pos - e.read_pos;
        try w.print(" {s:<24} {d:>5}  {d:>4}  {d:>5}  {d:>5}  {d:>4}  {d:>5}\n", .{
            e.name[0..e.name_len], e.msg_size, e.capacity, e.conns,
            e.write_pos, e.read_pos, depth,
        });
    }
}
