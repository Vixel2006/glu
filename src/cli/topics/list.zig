const std = @import("std");
const utils = @import("../utils.zig");
const table = @import("../table.zig");
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

    var t = table.Table.init(&.{
        .{ .header = "Topic" },
        .{ .header = "Size", .right = true },
        .{ .header = "Cap", .right = true },
        .{ .header = "Conns", .right = true },
        .{ .header = "Write", .right = true },
        .{ .header = "Read", .right = true },
        .{ .header = "Depth", .right = true },
    });

    for (entry_buf[0..count]) |e| {
        var cells: [7][16]u8 = undefined;
        const depth = e.write_pos - e.read_pos;
        const row = [_][]const u8{
            e.name[0..@min(e.name_len, e.name.len)],
            std.fmt.bufPrint(&cells[1], "{d}", .{e.msg_size}) catch unreachable,
            std.fmt.bufPrint(&cells[2], "{d}", .{e.capacity}) catch unreachable,
            std.fmt.bufPrint(&cells[3], "{d}", .{e.conns}) catch unreachable,
            std.fmt.bufPrint(&cells[4], "{d}", .{e.write_pos}) catch unreachable,
            std.fmt.bufPrint(&cells[5], "{d}", .{e.read_pos}) catch unreachable,
            std.fmt.bufPrint(&cells[6], "{d}", .{depth}) catch unreachable,
        };
        t.row(&row);
    }

    try t.render(w);
}
