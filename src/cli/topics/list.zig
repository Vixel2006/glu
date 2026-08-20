const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const discovery = @import("../../discovery/mod.zig");

/// List all active glu topics in shared memory (`glu topics list`, aliases `glu list`/`glu ls`).
pub fn cmd_list(init: std.process.Init, args: *parser.Args) !void {
    _ = args;
    var fw = utils.writer(init);
    const w = &fw.interface;

    var entry_buf: [128]discovery.TopicEntry = undefined;
    const count = discovery.scan_topics(&entry_buf) catch |err| switch (err) {
        error.ShmDirInaccessible => {
            try w.writeAll("error: /dev/shm not accessible\n");
            return;
        },
    };

    if (count == 0) {
        try w.writeAll("no active topics\n");
        return;
    }

    try w.print("{s:<24} {s:>8} {s:>8} {s:>6} {s:>8} {s:>8} {s:>6}\n", .{ "Topic", "Size", "Cap", "Conns", "Write", "Read", "Depth" });
    try w.print("{s:<24} {s:>8} {s:>8} {s:>6} {s:>8} {s:>8} {s:>6}\n", .{ "------------------------", "--------", "--------", "------", "--------", "--------", "------" });

    for (entry_buf[0..count]) |e| {
        const depth = e.write_pos - e.read_pos;
        try w.print("{s:<24} {d:>8} {d:>8} {d:>6} {d:>8} {d:>8} {d:>6}\n", .{
            e.name[0..@min(e.name_len, e.name.len)],
            e.msg_size,
            e.capacity,
            e.conns,
            e.write_pos,
            e.read_pos,
            depth,
        });
    }
}
