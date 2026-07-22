const std = @import("std");
const utils = @import("utils.zig");
const topic = @import("../topic/mod.zig");

/// List all active glu topics in shared memory (`glu list` / `glu ls`).
pub fn cmdList(init: std.process.Init) !void {
    const allocator = init.gpa;
    var fw = utils.writer(init);
    const w = &fw.interface;

    const entries = topic.scanTopics(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ShmDirInaccessible => {
            try w.writeAll("error: /dev/shm not accessible\n");
            return;
        },
    };
    defer {
        for (entries) |*e| e.deinit(allocator);
        allocator.free(entries);
    }

    if (entries.len == 0) {
        try w.writeAll("no active topics\n");
        return;
    }

    try w.writeAll(" Topic                    Size    Cap  Conns  Write  Read  Depth\n");
    try w.writeAll(" ──────────────────────── ─────── ──── ────── ────── ───── ──────\n");
    for (entries) |e| {
        const depth = e.write_pos - e.read_pos;
        try w.print(" {s:<24} {d:>5}  {d:>4}  {d:>5}  {d:>5}  {d:>4}  {d:>5}\n", .{
            e.name,      e.msg_size, e.capacity, e.conns,
            e.write_pos, e.read_pos, depth,
        });
    }
}
