const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const constants = @import("../../constants.zig");
const protocol = @import("../../daemon/protocol.zig");
const daemon_client = @import("../../daemon/client.zig");
const IO = @import("../../io.zig").IO;

fn print_node(w: anytype, n: *const protocol.Node) !void {
    var pid_buf: [16]u8 = undefined;
    var up_buf: [32]u8 = undefined;
    const alive = n.pid != null;
    const pid = if (n.pid) |p| std.fmt.bufPrint(&pid_buf, "{d}", .{p}) catch unreachable else "-";
    const uptime = utils.format_uptime(&up_buf, if (alive) utils.uptime_secs(n) else 0);
    try w.print("{s:<20} {s:>7} {s:<10} {s:<16} {s:<32} {s:<12}\n", .{
        n.name_slice(),
        pid,
        uptime,
        if (alive) "running" else "stopped",
        n.bin_slice(),
        n.path_slice(),
    });
}

/// List registered nodes (`glu nodes list`).
pub fn cmd_list(init: std.process.Init, args: *parser.Args) !void {
    _ = args;
    var fw = utils.writer(init);
    const w = &fw.interface;

    var io = try IO.init(32, 0);
    defer io.deinit();
    var client = try daemon_client.Client.ensure_running(&io);
    defer client.deinit();

    var nodes: [constants.MAX_ENTRIES]protocol.Node = undefined;
    const count = client.list_nodes(&nodes) catch |err| {
        w.print("error: cannot reach daemon: {}\n", .{err}) catch {};
        return;
    };

    try w.print("{s:<20} {s:>7} {s:<10} {s:<16} {s:<32} {s:<12}\n", .{ "Name", "PID", "Uptime", "Status", "Binary", "Path" });
    for (nodes[0..count]) |n| try print_node(w, &n);
}
