const std = @import("std");
const utils = @import("utils.zig");
const Registry = @import("../registry.zig");

/// List registered glu nodes (`glu ps`).
pub fn cmd_ps(init: std.process.Init) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    var entry_buf: [128]Registry.NodeEntry = undefined;
    const count = Registry.list_alive(&entry_buf) catch |err| {
        try w.print("error: cannot list nodes: {}\n", .{err});
        return;
    };

    if (count == 0) {
        try w.writeAll("no registered nodes\n");
        return;
    }

    try w.writeAll(" Node                     PID       Status\n");
    try w.writeAll(" ──────────────────────── ───────── ──────\n");
    for (entry_buf[0..count]) |e| {
        const status = if (e.alive) "alive" else "dead";
        try w.print(" {s:<24} {d:>9} {s:>6}\n", .{ e.name[0..e.name_len], e.pid, status });
    }
}
