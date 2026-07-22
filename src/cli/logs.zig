const std = @import("std");
const utils = @import("utils.zig");
const debug = @import("../debug/mod.zig");

/// Print logs for a node (`glu logs [--tail <n>] [--head <n>] <node>`).
pub fn cmdLogs(init: std.process.Init, args: *std.process.Args.Iterator, logs_dir: []const u8) !void {
    var tail: ?u64 = null;
    var head: ?u64 = null;
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
        } else {
            node = arg;
        }
    }

    const node_name = node orelse {
        var ew = utils.errWriter(init);
        ew.interface.print("usage: glu logs [--tail <n>] [--head <n>] <node>\n", .{}) catch {};
        return error.MissingArgument;
    };

    if (tail == null and head == null) tail = 10;

    var ew = utils.errWriter(init);
    const w = &ew.interface;

    if (head) |n| {
        const content = try debug.readLogHead(init.io, init.gpa, logs_dir, node_name, n);
        if (content) |c| {
            defer init.gpa.free(c);
            try w.print("{s}\n", .{c});
        }
    } else if (tail) |n| {
        const content = try debug.readLogTail(init.io, init.gpa, logs_dir, node_name, n);
        if (content) |c| {
            defer init.gpa.free(c);
            try w.print("{s}\n", .{c});
        }
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

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);

    const err = cmdLogs(init, &args_iter, "/nonexistent");
    try std.testing.expectError(error.MissingArgument, err);
}
