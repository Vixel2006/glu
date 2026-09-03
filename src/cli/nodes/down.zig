const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const debug = @import("../../debug/mod.zig");
const dispatch = @import("../dispatch.zig");
const daemon_client = @import("../../daemon/client.zig");
const protocol = @import("../../daemon/protocol.zig");

/// Stop one or more named nodes (`glu nodes stop <node> [node...]`).
pub fn cmd_stop(init: std.process.Init, args: *parser.Args) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    var client = try dispatch.get_client(init);
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

    if (!any) {
        var ew = utils.err_writer(init);
        ew.interface.print("usage: glu nodes stop <node> [node...]\n", .{}) catch {};
        return error.MissingArgument;
    }
}

/// Stop all registered nodes, or only the named ones
/// (`glu nodes down [node...]`).
pub fn cmd_down(init: std.process.Init, args: *parser.Args) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    var client = try dispatch.get_client(init);
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

    if (any) {
        debug.cleanup_logs(init.io);
        return;
    }

    var nodes_buf: [128]protocol.WireNode = undefined;
    const count = client.list_nodes(&nodes_buf) catch 0;
    var stopped: usize = 0;
    for (nodes_buf[0..count]) |e| {
        if (client.stop_node(e.name[0..e.name_len]) catch false) stopped += 1;
    }

    if (stopped == 0) {
        try w.writeAll("no running nodes\n");
        return;
    }

    try w.print("stopped {d} node(s)\n", .{stopped});
    debug.cleanup_logs(init.io);
}
