const std = @import("std");
const utils = @import("utils.zig");
const parser = @import("parser.zig");
const Registry = @import("../registry.zig");
const discovery = @import("../discovery/mod.zig");
const constants = @import("../constants.zig");

/// Unified node + topic overview (`glu status`).
pub fn cmd_status(init: std.process.Init, args: *parser.Args) !void {
    _ = args;
    var fw = utils.writer(init);
    const w = &fw.interface;

    var node_buf: [constants.MAX_ENTRIES]Registry.NodeEntry = undefined;
    const node_count = Registry.list_alive(&node_buf) catch |err| {
        try w.print("error: cannot read system state: {}\n", .{err});
        return;
    };
    var topic_buf: [constants.MAX_ENTRIES]discovery.TopicEntry = undefined;
    const topic_count = discovery.scan_topics(&topic_buf) catch |err| {
        try w.print("error: cannot read system state: {}\n", .{err});
        return;
    };

    try w.print("nodes ({d}):\n", .{node_count});
    try w.print("{s:<20} {s:>6} {s:<10} {s:<6} {s:>6}\n", .{ "Node", "PID", "Uptime", "Status", "Topics" });
    try w.print("{s:<20} {s:>6} {s:<10} {s:<6} {s:>6}\n", .{ "--------------------", "------", "----------", "------", "------" });
    for (node_buf[0..node_count]) |n| {
        var pid_buf: [16]u8 = undefined;
        var up_buf: [32]u8 = undefined;
        var owned: usize = 0;
        for (topic_buf[0..topic_count]) |t| {
            if (t.owner_pid == n.pid) owned += 1;
        }
        const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{n.pid}) catch unreachable;
        const uptime = utils.format_uptime(&up_buf, if (n.alive) utils.proc_uptime(n.pid) else 0);
        try w.print("{s:<20} {s:>6} {s:<10} {s:<6} {d:>6}\n", .{
            n.name[0..n.name_len],
            pid,
            uptime,
            if (n.alive) "alive" else "dead",
            owned,
        });
    }

    try w.writeByte('\n');
    try w.print("topics ({d}):\n", .{topic_count});
    try w.print("{s:<24} {s:<16} {s:<11} {s:>8} {s:>6} {s:>8}\n", .{ "Topic", "Owner", "TOS", "Size", "Depth", "Cap" });
    try w.print("{s:<24} {s:<16} {s:<11} {s:>8} {s:>6} {s:>8}\n", .{ "------------------------", "----------------", "-----------", "--------", "------", "--------" });
    for (topic_buf[0..topic_count]) |t| {
        var owner_buf: [64]u8 = undefined;
        const depth = t.write_pos - t.read_pos;
        try w.print("{s:<24} {s:<16} {s:<11} {d:>8} {d:>6} {d:>8}\n", .{
            t.name[0..t.name_len],
            owner_name(&owner_buf, node_buf[0..node_count], t.owner_pid),
            if (t.tos == 0) "reliable" else "best_effort",
            t.msg_size,
            depth,
            t.capacity,
        });
    }
}

/// The node owning a topic, or its raw PID when unregistered.
///
/// Copies into `buf` (the for-loop variable would dangle once this returns).
fn owner_name(buf: []u8, nodes: []const Registry.NodeEntry, pid: u32) []const u8 {
    if (pid == 0) return "-";
    for (nodes) |n| {
        if (n.pid == pid) {
            const len: usize = @min(n.name_len, @as(u32, @intCast(buf.len)));
            @memcpy(buf[0..len], n.name[0..len]);
            return buf[0..len];
        }
    }
    return std.fmt.bufPrint(buf, "{d}", .{pid}) catch "-";
}

