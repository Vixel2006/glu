const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const management = @import("../../management/process.zig");

/// Stop one or more named nodes (`glu nodes stop <node> [node...]`).
pub fn cmd_stop(init: std.process.Init, args: *parser.Args) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    var any = false;
    while (args.next()) |name| {
        any = true;
        const stopped = management.stop_node(init.io, name) catch |err| {
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
