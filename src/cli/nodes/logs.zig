const std = @import("std");
const utils = @import("../utils.zig");
const parser = @import("../parser.zig");
const debug = @import("../../debug/mod.zig");
const constants = @import("../../constants.zig");

/// Print logs for a node (`glu nodes logs [--tail <n>] [--head <n>] [-f] <node>`).
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
        } else if (std.mem.eql(u8, arg, "--head")) {
            head = 10;
            tail = null;
            if (args.next()) |n_str| {
                head = std.fmt.parseInt(u64, n_str, 10) catch 10;
            }
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--follow")) {
            follow = true;
        } else {
            node = arg;
        }
    }

    const node_name = node orelse {
        var ew = utils.err_writer(init);
        ew.interface.print("usage: glu nodes logs [--tail <n>] [--head <n>] [-f] <node>\n", .{}) catch {};
        return error.MissingArgument;
    };

    if (tail == null and head == null) tail = 10;

    if (follow) {
        try print_logs(init, node_name, tail, head);
        try follow_logs(init, node_name);
        return;
    }

    try print_logs(init, node_name, tail, head);
}

/// Print the initial `--head`/`--tail` window, if any.
fn print_logs(init: std.process.Init, node: []const u8, tail: ?u64, head: ?u64) !void {
    var ew = utils.err_writer(init);
    const w = &ew.interface;

    var buf: [4096]u8 = undefined;
    if (head) |n| {
        const len = try debug.read_log_head(constants.LOGS_DIR, node, n, &buf);
        if (len > 0) try w.print("{s}\n", .{buf[0..len]});
    } else if (tail) |n| {
        const len = try debug.read_log_tail(constants.LOGS_DIR, node, n, &buf);
        if (len > 0) try w.print("{s}\n", .{buf[0..len]});
    }
}

/// Stream newly-appended log lines until interrupted (Ctrl-C).
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

test "logs: missing argument returns error" {
    const c = std.c;
    const devnull = c.open("/dev/null", std.os.linux.O{ .ACCMODE = .WRONLY }, @as(c_uint, 0));
    const saved_stderr = c.dup(2);
    _ = c.dup2(devnull, 2);
    defer {
        _ = c.dup2(saved_stderr, 2);
        _ = c.close(saved_stderr);
        _ = c.close(devnull);
    }

    const init = std.process.Init{
        .minimal = .{
            .environ = std.process.Environ.empty,
            .args = .{ .vector = &.{} },
        },
        .arena = undefined,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = undefined,
        .preopens = std.process.Preopens.empty,
    };

    var args = parser.Args.init(init);
    const err = cmd_logs(init, &args);
    try std.testing.expectError(error.MissingArgument, err);
}
