const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const management = @import("../../management/process.zig");
const constants = @import("../../constants.zig");

/// Start one or more named nodes from their persisted manifest
/// (`glu nodes start <node> [node...]`).
pub fn cmd_start(init: std.process.Init, args: *parser.Args) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    var any = false;
    while (args.next()) |name| {
        any = true;
        const started = management.start_node(init.io, name, constants.LOGS_DIR) catch |err| {
            try w.print("start {s}: {s}\n", .{ name, @errorName(err) });
            continue;
        };
        if (started) {
            try w.print("started {s}\n", .{name});
        } else {
            try w.print("{s}: no launch manifest (was it launched by glu?)\n", .{name});
        }
    }

    if (!any) {
        var ew = utils.err_writer(init);
        ew.interface.print("usage: glu nodes start <node> [node...]\n", .{}) catch {};
        return error.MissingArgument;
    }
}
