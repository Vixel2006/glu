const std = @import("std");
const utils = @import("utils.zig");

const LOGS_DIR = "/tmp/glu/logs";

pub fn cleanupLogs(io: std.Io) void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, LOGS_DIR) catch {};
}

fn countHeadLines(buf: []const u8, n: u64) usize {
    var end: usize = 0;
    var line_count: u64 = 0;
    while (end < buf.len) : (end += 1) {
        if (buf[end] == '\n') {
            line_count += 1;
            if (line_count == n) return end + 1;
        }
    }
    return buf.len;
}

fn countTailLines(buf: []const u8, n: u64) usize {
    var start: usize = 0;
    var line_count: u64 = 0;
    var i = buf.len;
    if (i > 0 and buf[i - 1] == '\n') i -= 1;
    while (i > 0) {
        i -= 1;
        if (buf[i] == '\n') {
            line_count += 1;
            if (line_count == n) {
                start = i + 1;
                break;
            }
        }
    }
    return start;
}

/// Print logs for a node (`glu logs [--tail <n>] [--head <n>] <node>`).
pub fn cmdLogs(init: std.process.Init, args: *std.process.Args.Iterator) void {
    cmdLogs_(init, args, LOGS_DIR) catch |err| utils.logErr("info", err);
}

pub fn cmdLogs_(init: std.process.Init, args: *std.process.Args.Iterator, logs_dir: []const u8) !void {
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
        std.debug.print("usage: glu logs [--tail <n>] [--head <n>] <node>\n", .{});
        return error.MissingArgument;
    };

    if (tail == null and head == null) tail = 10;

    const cwd = std.Io.Dir.cwd();

    const dir = try cwd.openDir(init.io, logs_dir, .{ .iterate = true });
    defer dir.close(init.io);

    var iter = dir.iterate();

    while (try iter.next(init.io)) |log| {
        if (std.mem.eql(u8, log.name[0 .. log.name.len - 4], node_name)) {
            const file = try dir.openFile(init.io, log.name, .{});
            defer file.close(init.io);

            const file_len = try file.length(init.io);

            const MAX_BUF: u64 = 4096;

            if (head) |n| {
                const to_read = @min(file_len, MAX_BUF);
                if (to_read == 0) return;
                var buf: [MAX_BUF]u8 = undefined;
                _ = try file.readPositionalAll(init.io, buf[0..to_read], 0);
                const end = countHeadLines(buf[0..to_read], n);
                if (end > 0) std.debug.print("{s}\n", .{buf[0..end]});
            } else if (tail) |n| {
                const to_read = @min(file_len, MAX_BUF);
                if (to_read == 0) return;
                const offset = file_len - to_read;
                var buf: [MAX_BUF]u8 = undefined;
                _ = try file.readPositionalAll(init.io, buf[0..to_read], offset);
                const start = countTailLines(buf[0..to_read], n);
                if (start < to_read) std.debug.print("{s}\n", .{buf[start..to_read]});
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
