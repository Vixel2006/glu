const std = @import("std");
const utils = @import("../utils.zig");
const table = @import("../table.zig");
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

    var t = table.Table.init(&.{
        .{ .header = "Node" },
        .{ .header = "PID", .right = true },
        .{ .header = "Uptime" },
        .{ .header = "Status", .right = true },
    });

    for (entry_buf[0..count]) |e| {
        var pid_buf: [16]u8 = undefined;
        var up_buf: [32]u8 = undefined;
        const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{e.pid}) catch unreachable;
        const uptime = utils.format_uptime(&up_buf, e.uptime);
        t.row(&.{ e.name[0..e.name_len], pid, uptime, if (e.alive) "alive" else "dead" });
    }

    try t.render(w);
}
