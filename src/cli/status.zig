const std = @import("std");
const utils = @import("utils.zig");
const parser = @import("parser.zig");
const constants = @import("../constants.zig");
const protocol = @import("../daemon/protocol.zig");
const daemon_client = @import("../daemon/client.zig");
const IO = @import("../io.zig").IO;

/// Unified node + topic overview (`glu status`).
pub fn cmd_status(init: std.process.Init, args: *parser.Args) !void {
    _ = args;
    var fw = utils.writer(init);
    const w = &fw.interface;

    var io = try IO.init(32, 0);
    defer io.deinit();
    var client = try daemon_client.Client.ensure_running(&io);
    defer client.deinit();

    var node_buf: [constants.MAX_ENTRIES]protocol.Node = undefined;
    const nodes = node_buf[0..try client.list_nodes(&node_buf)];

    try w.print("nodes ({d}):\n", .{nodes.len});
    try w.print("{s:<20} {s:>6} {s:<10} {s:<6} {s:>6}\n", .{ "Node", "PID", "Uptime", "Status", "Topics" });
    try w.print("{s:<20} {s:>6} {s:<10} {s:<6} {s:>6}\n", .{ "--------------------", "------", "----------", "------", "------" });
    for (nodes) |n| {
        var pid_buf: [16]u8 = undefined;
        var up_buf: [32]u8 = undefined;
        const alive = n.pid != null;
        const pid = if (n.pid) |p| std.fmt.bufPrint(&pid_buf, "{d}", .{p}) catch unreachable else "-";
        const uptime = utils.format_uptime(&up_buf, if (alive) utils.uptime_secs(&n) else 0);
        try w.print("{s:<20} {s:>6} {s:<10} {s:<6} {d:>6}\n", .{
            n.name_slice(),
            pid,
            uptime,
            if (alive) "alive" else "dead",
            0,
        });
    }

    var topic_buf: [constants.MAX_ENTRIES]protocol.SHM_CHAN = undefined;
    const topics = topic_buf[0..(client.list_topics(&topic_buf) catch 0)];

    try w.writeByte('\n');
    try w.print("topics ({d}):\n", .{topics.len});
    try w.print("{s:<24} {s:<16} {s:<11} {s:>8} {s:>8}\n", .{ "Topic", "Owner", "TOS", "Size", "Cap" });
    try w.print("{s:<24} {s:<16} {s:<11} {s:>8} {s:>8}\n", .{ "------------------------", "----------------", "-----------", "--------", "--------" });
    for (topics) |t| {
        var owner_buf: [64]u8 = undefined;
        try w.print("{s:<24} {s:<16} {s:<11} {d:>8} {d:>8}\n", .{
            t.name[0..t.name_len],
            owner_name(&owner_buf, nodes, t.writer_pid),
            if (t.tos == 0) "reliable" else "best_effort",
            t.msg_size,
            t.capacity,
        });
    }
}

/// The node owning a topic, or its raw PID when unregistered.
fn owner_name(buf: []u8, nodes: []protocol.Node, pid: std.os.linux.pid_t) []const u8 {
    if (pid == 0) return "-";
    for (nodes) |n| {
        if (n.pid) |p| {
            if (p == pid) {
                return n.name_slice();
            }
        }
    }
    return std.fmt.bufPrint(buf, "{d}", .{pid}) catch "-";
}
