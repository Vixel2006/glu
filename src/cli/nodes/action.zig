const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const daemon_client = @import("../../daemon/client.zig");
const IO = @import("../../io.zig").IO;

fn node_action(
    init: std.process.Init,
    args: *parser.Args,
    comptime verb: []const u8,
    action: *const fn (*daemon_client.Client, []const u8) anyerror!bool,
) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    var io = try IO.init(32, 0);
    defer io.deinit();
    var client = try daemon_client.Client.ensure_running(&io);
    defer client.deinit();

    var any = false;
    while (args.next()) |name| {
        any = true;
        const ok = action(&client, name) catch |err| {
            try w.print(verb ++ " {s}: {s}\n", .{ name, @errorName(err) });
            continue;
        };
        if (ok) {
            const past = comptime if (std.mem.eql(u8, verb, "stop")) "stopped" else verb ++ "ed";
            try w.print(past ++ " {s}\n", .{name});
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

fn start_fn(client: *daemon_client.Client, name: []const u8) !bool {
    return client.start_node(name);
}

fn stop_fn(client: *daemon_client.Client, name: []const u8) !bool {
    return client.stop_node(name);
}

fn restart_fn(client: *daemon_client.Client, name: []const u8) !bool {
    return client.restart_node(name);
}

/// Start one or more named nodes (`glu nodes start <node> [node...]`).
pub fn cmd_start(init: std.process.Init, args: *parser.Args) !void {
    return node_action(init, args, "start", start_fn);
}

/// Stop one or more named nodes (`glu nodes stop <node> [node...]`).
pub fn cmd_stop(init: std.process.Init, args: *parser.Args) !void {
    return node_action(init, args, "stop", stop_fn);
}

/// Restart one or more named nodes (`glu nodes restart <node> [node...]`).
pub fn cmd_restart(init: std.process.Init, args: *parser.Args) !void {
    return node_action(init, args, "restart", restart_fn);
}
