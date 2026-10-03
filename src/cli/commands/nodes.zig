const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const constants = @import("../../constants.zig");
const protocol = @import("../../daemon/protocol.zig");
const daemon_client = @import("../../daemon/client.zig");
const IO = @import("../../io.zig").IO;
const debug = @import("../../debug/mod.zig");

pub fn cmd_list(init: std.process.Init, args: *parser.Args) !void {
    _ = args;
    var fw = utils.writer(init);
    const w = &fw.interface;

    var io = try IO.init(32, 0);
    defer io.deinit();
    var client = try daemon_client.Client.ensure_running(&io);
    defer client.deinit();

    var nodes_buf: [constants.MAX_ENTRIES]protocol.Node = undefined;
    const count = try client.list_nodes(&nodes_buf);

    if (count == 0) {
        try w.writeAll("no nodes running\n");
        return;
    }
    try w.print("{s:<20} {s:>7} {s:<10} {s:<16} {s:<32} {s:<12}\n", .{ "Name", "PID", "Uptime", "Status", "Binary", "Path" });
    for (nodes_buf[0..count]) |n| {
        try print_node(w, &n);
    }
}

fn print_node(w: *std.Io.Writer, n: *protocol.Node) !void {
    var pid_buf: [16]u8 = undefined;
    var up_buf: [32]u8 = undefined;
    const alive = n.pid != null;
    const pid = if (n.pid) |p| std.fmt.bufPrint(&pid_buf, "{d}", .{p}) catch unreachable else "-";
    const uptime = utils.format_uptime(&up_buf, if (alive) utils.uptime_secs(n) else 0);
    try w.print("{s:<20} {s:>7} {s:<10} {s:<16} {s:<32} {s:<12}\n", .{
        n.name_slice(),
        pid,
        uptime,
        if (alive) "running" else "stopped",
        n.bin_slice(),
        n.path_slice(),
    });
}

// action helpers
pub fn cmd_start(init: std.process.Init, args: *parser.Args) !void {
    return node_action(init, args, "start", start_fn);
}

pub fn cmd_stop(init: std.process.Init, args: *parser.Args) !void {
    return node_action(init, args, "stop", stop_fn);
}

pub fn cmd_restart(init: std.process.Init, args: *parser.Args) !void {
    return node_action(init, args, "restart", restart_fn);
}

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

pub fn cmd_logs(init: std.process.Init, args: *parser.Args) !void {
    var tail: ?u64 = null;
    var head: ?u64 = null;
    var follow = false;
    var node: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--tail")) {
            tail = 10;
            head = null;
            if (args.next()) |n_str| {
                tail = std.fmt.parseInt(u64, n_str, 10) catch 10;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--head")) {
            head = 10;
            tail = null;
            if (args.next()) |n_str| {
                head = std.fmt.parseInt(u64, n_str, 10) catch 10;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--follow")) {
            follow = true;
            continue;
        }
        node = arg;
    }

    const nname = node orelse {
        var ew = utils.err_writer(init);
        ew.interface.writeAll("usage: glu nodes logs [--tail <n>] [--head <n>] [-f] <node>\n") catch {};
        return error.MissingArgument;
    };

    if (follow) {
        try follow_logs(init, nname);
        return;
    }
    try print_logs(init, nname, tail, head);
}

fn print_logs(init: std.process.Init, node: []const u8, tail: ?u64, head: ?u64) !void {
    var fw = utils.writer(init);
    const w = &fw.interface;

    var buf: [4096]u8 = undefined;
    if (head) |n| {
        const len = try debug.read_log_head(constants.LOGS_DIR, node, n, &buf);
        if (len > 0) try w.print("{s}\n", .{buf[0..len]});
    } else if (tail) |n| {
        const len = try debug.read_log_tail(constants.LOGS_DIR, node, n, &buf);
        if (len > 0) try w.print("{s}\n", .{buf[0..len]});
    }
}

fn follow_logs(init: std.process.Init, node: []const u8) !void {
    var follower = try debug.LogFollower.init(constants.LOGS_DIR, node);
    defer follower.deinit();

    var ew = utils.err_writer(init);
    const w = &ew.interface;

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try follower.poll(init.io, &buf);
        if (n > 0) try w.writeAll(buf[0..n]);
    }
}

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
