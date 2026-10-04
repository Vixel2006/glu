const std = @import("std");
const utils = @import("utils.zig");
const protocol = @import("../daemon/protocol.zig");
const daemon_client = @import("../daemon/client.zig");
const IO = @import("../io.zig").IO;
const constants = @import("../constants.zig");

/// Port derivation for multicast on a channel name.
pub fn port_for_name(name: []const u8) u16 {
    const h = std.hash.Fnv1a_64.hash(name);
    const base: u32 = constants.PORT_BASE;
    const slots: u32 = constants.PORT_SLOTS;
    return @intCast(base + @as(u32, @intCast(h % slots)));
}

/// Resolve owner PID to a node name from the node list.
pub fn resolve_owner(buf: []u8, nodes: []protocol.Node, pid: std.os.linux.pid_t) []const u8 {
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

/// Resolve owner PID to a name-or-PID string from the node list.
pub fn owner_name_or_pid(buf: []u8, nodes: []protocol.Node, pid: std.os.linux.pid_t) []const u8 {
    if (pid == 0) return "-";
    for (nodes) |n| {
        if (n.pid) |p| {
            if (p == pid) {
                return n.name_slice();
            }
        }
    }
    return std.fmt.bufPrint(buf, "PID:{d}", .{pid}) catch "-";
}
