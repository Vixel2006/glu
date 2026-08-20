const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const management = @import("../../management/process.zig");
const constants = @import("../../constants.zig");

fn node_action(
    init: std.process.Init,
    args: *parser.Args,
    comptime verb: []const u8,
    action: *const fn (std.Io, []const u8, []const u8) anyerror!bool,
) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    var any = false;
    while (args.next()) |name| {
        any = true;
        const ok = action(init.io, name, constants.LOGS_DIR) catch |err| {
            try w.print(verb ++ " {s}: {s}\n", .{ name, @errorName(err) });
            continue;
        };
        if (ok) {
            try w.print(verb ++ "ed {s}\n", .{name});
        } else {
            try w.print("{s}: no launch manifest (was it launched by glu?)\n", .{name});
        }
    }

    if (!any) {
        var ew = utils.err_writer(init);
        ew.interface.print("usage: glu nodes " ++ verb ++ " <node> [node...]\n", .{}) catch {};
        return error.MissingArgument;
    }
}

fn restart_fn(io: std.Io, name: []const u8, logs_dir: []const u8) !bool {
    _ = try management.stop_node(io, name);
    return try management.start_node(io, name, logs_dir);
}

/// Start one or more named nodes (`glu nodes start <node> [node...]`).
pub fn cmd_start(init: std.process.Init, args: *parser.Args) !void {
    return node_action(init, args, "start", management.start_node);
}

/// Restart one or more named nodes (`glu nodes restart <node> [node...]`).
pub fn cmd_restart(init: std.process.Init, args: *parser.Args) !void {
    return node_action(init, args, "restart", restart_fn);
}
