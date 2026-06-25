const std = @import("std");
const utils = @import("utils.zig");

const LOGS_DIR = "/tmp/glu/logs";

pub fn cleanupLogs(io: std.Io) void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, LOGS_DIR) catch {};
}

pub fn cmdLogs(init: std.process.Init, args: *std.process.Args.Iterator) void {
    cmdLogs_(init, args, LOGS_DIR) catch |err| utils.logErr("info", err);
}

pub fn cmdLogs_(init: std.process.Init, args: *std.process.Args.Iterator, logs_dir: []const u8) !void {
    var tail: ?u64 = null;
    var head: ?u64 = null;
    var node: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--tail")) {
            tail = 4096;
            head = null;
            if (args.next()) |n_str| {
                tail = std.fmt.parseInt(u64, n_str, 10) catch 4096;
            }
        } else if (std.mem.eql(u8, arg, "--head")) {
            head = 4096;
            tail = null;
            if (args.next()) |n_str| {
                head = std.fmt.parseInt(u64, n_str, 10) catch 4096;
            }
        } else {
            node = arg;
        }
    }

    const node_name = node orelse {
        std.debug.print("usage: glu logs [--tail <n>] [--head <n>] <node>\n", .{});
        return error.MissingArgument;
    };

    if (tail == null and head == null) tail = 4096;

    const cwd = std.Io.Dir.cwd();

    const dir = try cwd.openDir(init.io, logs_dir, .{ .iterate = true });
    defer dir.close(init.io);

    var iter = dir.iterate();

    while (try iter.next(init.io)) |log| {
        if (std.mem.eql(u8, log.name[0 .. log.name.len - 4], node_name)) {
            const file = try dir.openFile(init.io, log.name, .{});
            defer file.close(init.io);

            const file_len = try file.length(init.io);

            if (head) |n| {
                const to_read = @min(n, file_len);
                if (to_read == 0) return;
                var buf: [4096]u8 = undefined;
                const buf_len = @min(to_read, @as(u64, buf.len));
                _ = try file.readPositionalAll(init.io, buf[0..buf_len], 0);
                std.debug.print("{s}\n", .{buf[0..buf_len]});
            } else if (tail) |n| {
                const to_read = @min(n, file_len);
                if (to_read == 0) return;
                const offset = file_len - to_read;
                var buf: [4096]u8 = undefined;
                const buf_len = @min(to_read, @as(u64, buf.len));
                _ = try file.readPositionalAll(init.io, buf[0..buf_len], offset);
                std.debug.print("{s}\n", .{buf[0..buf_len]});
            }

            return;
        }
    }
}

test "logs: missing argument returns error" {
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

    const err = cmdLogs_(init, &args_iter, "/nonexistent");
    try std.testing.expectError(error.MissingArgument, err);
}

test "logs: reads matching log file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(io, .{ .sub_path = "mynode.log", .data = "hello from mynode" });

    const logs_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&dir.sub_path});
    defer allocator.free(logs_dir);

    const init = std.process.Init{
        .minimal = .{
            .environ = std.process.Environ.empty,
            .args = .{ .vector = &.{"mynode"} },
        },
        .arena = undefined,
        .gpa = allocator,
        .io = io,
        .environ_map = undefined,
        .preopens = std.process.Preopens.empty,
    };

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);

    try cmdLogs_(init, &args_iter, logs_dir);
}

test "logs: no matching file silently returns" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(io, .{ .sub_path = "other.log", .data = "hello" });

    const logs_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&dir.sub_path});
    defer allocator.free(logs_dir);

    const init = std.process.Init{
        .minimal = .{
            .environ = std.process.Environ.empty,
            .args = .{ .vector = &.{"mynode"} },
        },
        .arena = undefined,
        .gpa = allocator,
        .io = io,
        .environ_map = undefined,
        .preopens = std.process.Preopens.empty,
    };

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);

    try cmdLogs_(init, &args_iter, logs_dir);
}
