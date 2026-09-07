const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const constants = @import("../../constants.zig");
const protocol = @import("../../daemon/protocol.zig");
const daemon_client = @import("../../daemon/client.zig");
const IO = @import("../../io.zig").IO;

/// Stop all registered nodes, or only the named ones
/// (`glu nodes down [node...]`).
pub fn cmd_down(init: std.process.Init, args: *parser.Args) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    var io = try IO.init(32, 0);
    defer io.deinit();
    var client = try daemon_client.Client.ensure_running(&io);
    defer client.deinit();

    var any = false;
    while (args.next()) |name| {
        any = true;
        const stopped = client.stop_node(name) catch |err| {
            try w.print("stop {s}: {s}\n", .{ name, @errorName(err) });
            continue;
        };
        if (stopped) {
            try w.print("stopped {s}\n", .{name});
        } else {
            try w.print("{s}: not running\n", .{name});
        }
    }
    if (any) return;

    var nodes_buf: [constants.MAX_ENTRIES]protocol.Node = undefined;
    const count = try client.list_nodes(&nodes_buf);
    var stopped: usize = 0;
    for (nodes_buf[0..count]) |e| {
        if (client.stop_node(e.name_slice()) catch false) stopped += 1;
    }

    if (stopped == 0) {
        try w.writeAll("no running nodes\n");
        return;
    }

    try w.print("stopped {d} node(s)\n", .{stopped});
}