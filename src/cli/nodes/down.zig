const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const node = @import("../../management/process.zig");
const debug = @import("../../debug/mod.zig");

/// Stop all registered nodes, or only the named ones
/// (`glu nodes down [node...]`).
pub fn cmd_down(init: std.process.Init, args: *parser.Args) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    var any = false;
    while (args.next()) |name| {
        any = true;
        const stopped = node.stop_node(init.io, name) catch |err| {
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

    const stopped = node.stop_all_nodes(init.io) catch 0;
    if (stopped == 0) {
        try w.writeAll("no running nodes\n");
        return;
    }

    try w.print("stopped {d} node(s)\n", .{stopped});
    debug.cleanup_logs(init.io);
}
