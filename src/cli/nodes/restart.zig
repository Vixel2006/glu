const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const management = @import("../../management/process.zig");

const DEFAULT_LOGS_DIR = "/tmp/glu/logs";

/// Restart one or more named nodes (`glu nodes restart <node> [node...]`).
///
/// Stops each running node, then re-spawns it from its persisted manifest.
pub fn cmd_restart(init: std.process.Init, args: *parser.Args) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    var any = false;
    while (args.next()) |name| {
        any = true;
        const restarted = management.restart_node(init.io, name, DEFAULT_LOGS_DIR) catch |err| {
            try w.print("restart {s}: {s}\n", .{ name, @errorName(err) });
            continue;
        };
        if (restarted) {
            try w.print("restarted {s}\n", .{name});
        } else {
            try w.print("{s}: no launch manifest (was it launched by glu?)\n", .{name});
        }
    }

    if (!any) {
        var ew = utils.err_writer(init);
        ew.interface.print("usage: glu nodes restart <node> [node...]\n", .{}) catch {};
        return error.MissingArgument;
    }
}
