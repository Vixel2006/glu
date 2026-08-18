const std = @import("std");
const utils = @import("utils.zig");
const table = @import("table.zig");
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

    var nt = table.Table.init(&.{
        .{ .header = "Node" },
        .{ .header = "PID", .right = true },
        .{ .header = "Uptime" },
        .{ .header = "Status" },
        .{ .header = "Topics", .right = true },
    });
    for (node_buf[0..node_count]) |n| {
        var pid_buf: [16]u8 = undefined;
        var up_buf: [32]u8 = undefined;
        var topics_buf: [16]u8 = undefined;
        var owned: usize = 0;
        for (topic_buf[0..topic_count]) |t| {
            if (t.owner_pid == n.pid) owned += 1;
        }
        nt.row(&.{
            n.name[0..n.name_len],
            std.fmt.bufPrint(&pid_buf, "{d}", .{n.pid}) catch unreachable,
            utils.format_uptime(&up_buf, n.uptime),
            if (n.alive) "alive" else "dead",
            std.fmt.bufPrint(&topics_buf, "{d}", .{owned}) catch unreachable,
        });
    }

    var tt = table.Table.init(&.{
        .{ .header = "Topic" },
        .{ .header = "Owner" },
        .{ .header = "TOS" },
        .{ .header = "Size", .right = true },
        .{ .header = "Depth", .right = true },
        .{ .header = "Cap", .right = true },
    });
    for (topic_buf[0..topic_count]) |t| {
        var owner_buf: [64]u8 = undefined;
        var size_buf: [16]u8 = undefined;
        var depth_buf: [16]u8 = undefined;
        var cap_buf: [16]u8 = undefined;
        const depth = t.write_pos - t.read_pos;
        tt.row(&.{
            t.name[0..t.name_len],
            owner_name(&owner_buf, node_buf[0..node_count], t.owner_pid),
            if (t.tos == 0) "reliable" else "best_effort",
            std.fmt.bufPrint(&size_buf, "{d}", .{t.msg_size}) catch unreachable,
            std.fmt.bufPrint(&depth_buf, "{d}", .{depth}) catch unreachable,
            std.fmt.bufPrint(&cap_buf, "{d}", .{t.capacity}) catch unreachable,
        });
    }

    try w.print("nodes ({d}):\n", .{node_count});
    try nt.render(w);
    try w.writeByte('\n');
    try w.print("topics ({d}):\n", .{topic_count});
    try tt.render(w);
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
