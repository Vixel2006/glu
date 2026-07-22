const std = @import("std");

const LOGS_DIR = "/tmp/glu/logs";
const MAX_LOG_BUF: usize = 4096;

/// Clean up the logs directory by deleting it entirely.
pub fn cleanupLogs(io: std.Io) void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, LOGS_DIR) catch {};
}

/// Count the byte offset after the first `n` lines in `buf`.
///
/// Used to extract the head of a log file.
pub fn countHeadLines(buf: []const u8, n: u64) usize {
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

/// Count the byte offset of the start of the last `n` lines in `buf`.
///
/// Used to extract the tail of a log file.
pub fn countTailLines(buf: []const u8, n: u64) usize {
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

/// Read the first `n` lines from a node's log file.
///
/// Returns an owned slice allocated with `allocator`, or `null` if
/// no matching log file is found. The caller must free the result.
pub fn readLogHead(io: std.Io, allocator: std.mem.Allocator, logs_dir: []const u8, node: []const u8, n: u64) !?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    const dir = cwd.openDir(io, logs_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |log| {
        if (log.name.len > 4 and
            std.mem.eql(u8, log.name[log.name.len - 4 ..], ".log") and
            std.mem.eql(u8, log.name[0 .. log.name.len - 4], node))
        {
            const file = try dir.openFile(io, log.name, .{});
            defer file.close(io);

            const file_len = try file.length(io);
            const to_read = @min(file_len, MAX_LOG_BUF);
            if (to_read == 0) return null;

            var buf: [MAX_LOG_BUF]u8 = undefined;
            _ = try file.readPositionalAll(io, buf[0..to_read], 0);

            const end = countHeadLines(buf[0..to_read], n);
            if (end == 0) return null;

            return try allocator.dupe(u8, buf[0..end]);
        }
    }
    return null;
}

/// Read the last `n` lines from a node's log file.
///
/// Returns an owned slice allocated with `allocator`, or `null` if
/// no matching log file is found. The caller must free the result.
pub fn readLogTail(io: std.Io, allocator: std.mem.Allocator, logs_dir: []const u8, node: []const u8, n: u64) !?[]const u8 {
    const cwd = std.Io.Dir.cwd();
    const dir = cwd.openDir(io, logs_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |log| {
        if (log.name.len > 4 and
            std.mem.eql(u8, log.name[log.name.len - 4 ..], ".log") and
            std.mem.eql(u8, log.name[0 .. log.name.len - 4], node))
        {
            const file = try dir.openFile(io, log.name, .{});
            defer file.close(io);

            const file_len = try file.length(io);
            const to_read = @min(file_len, MAX_LOG_BUF);
            if (to_read == 0) return null;

            const offset = file_len - to_read;
            var buf: [MAX_LOG_BUF]u8 = undefined;
            _ = try file.readPositionalAll(io, buf[0..to_read], offset);

            const start = countTailLines(buf[0..to_read], n);
            if (start >= to_read) return null;

            return try allocator.dupe(u8, buf[start..to_read]);
        }
    }
    return null;
}

test "countHeadLines: fewer lines than requested returns full buffer" {
    const buf = "line1\nline2\n";
    try std.testing.expectEqual(@as(usize, buf.len), countHeadLines(buf, 10));
}

test "countHeadLines: exact number of lines" {
    const buf = "line1\nline2\nline3\n";
    try std.testing.expectEqual(@as(usize, 18), countHeadLines(buf, 3));
}

test "countHeadLines: empty buffer" {
    try std.testing.expectEqual(@as(usize, 0), countHeadLines("", 5));
}

test "countTailLines: fewer lines than requested returns full buffer" {
    const buf = "line1\nline2\n";
    try std.testing.expectEqual(@as(usize, 0), countTailLines(buf, 10));
}

test "countTailLines: last two lines of three" {
    const buf = "line1\nline2\nline3\n";
    try std.testing.expectEqual(@as(usize, 6), countTailLines(buf, 2));
}

test "countTailLines: last line only" {
    const buf = "line1\nline2\nline3\n";
    try std.testing.expectEqual(@as(usize, 12), countTailLines(buf, 1));
}

test "countTailLines: empty buffer" {
    try std.testing.expectEqual(@as(usize, 0), countTailLines("", 5));
}

test "readLogTail: reads matching log file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(io, .{ .sub_path = "mynode.log", .data = "hello from mynode" });

    const logs_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&dir.sub_path});
    defer allocator.free(logs_dir);

    const result = try readLogTail(io, allocator, logs_dir, "mynode", 10);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("hello from mynode", result.?);
    allocator.free(result.?);
}

test "readLogTail: no matching file silently returns null" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(io, .{ .sub_path = "other.log", .data = "hello" });

    const logs_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&dir.sub_path});
    defer allocator.free(logs_dir);

    const result = try readLogTail(io, allocator, logs_dir, "mynode", 10);
    try std.testing.expect(result == null);
}

test "readLogHead: reads first lines of log file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(io, .{ .sub_path = "sensor.log", .data = "line1\nline2\nline3\nline4\nline5\n" });

    const logs_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&dir.sub_path});
    defer allocator.free(logs_dir);

    const result = try readLogHead(io, allocator, logs_dir, "sensor", 2);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("line1\nline2\n", result.?);
    allocator.free(result.?);
}
