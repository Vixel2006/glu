const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const constants = @import("../../constants.zig");
const protocol = @import("../../daemon/protocol.zig");
const daemon_client = @import("../../daemon/client.zig");
const IO = @import("../../io.zig").IO;

/// List all active glu topics in shared memory (`glu topics list`, aliases `glu list`/`glu ls`).
pub fn cmd_list(init: std.process.Init, args: *parser.Args) !void {
    _ = args;
    var fw = utils.writer(init);
    const w = &fw.interface;

    var io = try IO.init(32, 0);
    defer io.deinit();
    var client = try daemon_client.Client.ensure_running(&io);
    defer client.deinit();

    var node_buf: [constants.MAX_ENTRIES]protocol.Node = undefined;
    const nodes = node_buf[0..try client.list_nodes(&node_buf)];

    var entry_buf: [constants.MAX_ENTRIES]protocol.SHM_CHAN = undefined;
    const count = try client.list_topics(&entry_buf);

    if (count == 0) {
        try w.writeAll("no active topics\n");
        return;
    }

    try w.print("{s:<24} {s:>8} {s:>8} {s:>6} {s:>8}\n", .{ "Topic", "Size", "Cap", "TOS", "Owner" });
    try w.print("{s:<24} {s:>8} {s:>8} {s:>6} {s:>8}\n", .{ "------------------------", "--------", "--------", "------", "--------" });

    var owner_name_buf: [64]u8 = undefined;
    for (entry_buf[0..count]) |e| {
        const owner = owner_name(&owner_name_buf, nodes, e.writer_pid);
        const tos = if (e.tos == 0) "reliable" else "best_effort";
        try w.print("{s:<24} {d:>8} {d:>8} {s:>6} {s:>8}\n", .{
            e.name[0..@min(e.name_len, e.name.len)],
            e.msg_size,
            e.capacity,
            tos,
            owner,
        });
    }
}

/// The node owning a topic, or its raw PID when unregistered.
fn owner_name(buf: []u8, nodes: []protocol.Node, pid: std.os.linux.pid_t) []const u8 {
    if (pid == 0) return "-";
    for (nodes) |n| {
        if (n.pid) |p| {
            if (p == pid) {
                const name = n.name_slice();
                const len = @min(name.len, buf.len);
                @memcpy(buf[0..len], name[0..len]);
                return buf[0..len];
            }
        }
    }
    return std.fmt.bufPrint(buf, "{d}", .{pid}) catch "-";
}
