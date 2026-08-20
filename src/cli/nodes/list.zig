const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const Registry = @import("../../registry.zig");

/// List registered glu nodes (`glu nodes list`, alias `glu ps`).
pub fn cmd_list(init: std.process.Init, args: *parser.Args) !void {
    _ = args;
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

    try w.print("{s:<20} {s:>6} {s:<10} {s:>6}\n", .{ "Node", "PID", "Uptime", "Status" });
    try w.print("{s:<20} {s:>6} {s:<10} {s:>6}\n", .{ "--------------------", "------", "----------", "------" });

    for (entry_buf[0..count]) |e| {
        var pid_buf: [16]u8 = undefined;
        var up_buf: [32]u8 = undefined;
        const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{e.pid}) catch unreachable;
        const uptime = utils.format_uptime(&up_buf, if (e.alive) utils.proc_uptime(e.pid) else 0);
        try w.print("{s:<20} {s:>6} {s:<10} {s:>6}\n", .{ e.name[0..e.name_len], pid, uptime, if (e.alive) "alive" else "dead" });
    }
}
