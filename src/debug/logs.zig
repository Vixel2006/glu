const std = @import("std");
const constants = @import("../constants.zig");

/// Clean up the logs directory by deleting it entirely.
pub fn cleanup_logs(io: std.Io) void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, constants.LOGS_DIR) catch |err| {
        std.log.warn("failed to clean up logs dir '{s}': {}", .{ constants.LOGS_DIR, err });
    };
}

/// Count the byte offset after the first `n` lines in `buf`.
///
/// Used to extract the head of a log file.
pub fn count_head_lines(buf: []const u8, n: u64) usize {
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
pub fn count_tail_lines(buf: []const u8, n: u64) usize {
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

fn open_log_file(io: std.Io, logs_dir: []const u8, node: []const u8) !?std.Io.File {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.log", .{ logs_dir, node }) catch return error.NameTooLong;
    return std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

/// Read the first `n` lines from a node's log file into `buf`.
///
/// Returns the number of bytes written, or 0 when no matching
/// log file exists or the file is empty.
pub fn read_log_head(logs_dir: []const u8, node: []const u8, n: u64, buf: []u8) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = (try open_log_file(io, logs_dir, node)) orelse return 0;
    defer file.close(io);

    const size: u64 = @intCast(file.length(io) catch return 0);
    const to_read: usize = @intCast(@min(size, @as(u64, buf.len)));
    const got = file.readPositionalAll(io, buf[0..to_read], 0) catch return 0;

    return count_head_lines(buf[0..got], n);
}

/// Read the last `n` lines from a node's log file into `buf`.
///
/// Returns the number of bytes written, or 0 when no matching
/// log file exists or the file is empty.
pub fn read_log_tail(logs_dir: []const u8, node: []const u8, n: u64, buf: []u8) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    var file = (try open_log_file(io, logs_dir, node)) orelse return 0;
    defer file.close(io);

    const size: u64 = @intCast(file.length(io) catch return 0);
    const to_read: usize = @intCast(@min(size, @as(u64, buf.len)));
    const offset = if (size > to_read) size - to_read else 0;
    const got = file.readPositionalAll(io, buf[0..to_read], offset) catch return 0;

    const start = count_tail_lines(buf[0..got], n);
    const len = got - start;
    std.mem.copyForwards(u8, buf[0..len], buf[start..got]);
    return len;
}

/// A handle for streaming appended log bytes.
///
/// Holds the log file open, tracks the last-read offset, and reports
/// newly appended bytes on each `poll`.
pub const LogFollower = struct {
    file: std.Io.File,
    offset: u64,

    /// Open a node's log file for following. Errors with
    /// `error.FileNotFound` if no matching log exists.
    pub fn init(logs_dir: []const u8, node: []const u8) !LogFollower {
        const io = std.Io.Threaded.global_single_threaded.io();
        var file = (try open_log_file(io, logs_dir, node)) orelse return error.FileNotFound;
        errdefer file.close(io);
        const size: u64 = @intCast(try file.length(io));
        return .{ .file = file, .offset = size };
    }

    pub fn deinit(self: *LogFollower) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.file.close(io);
    }

    /// Read any bytes appended since the last poll into `buf`.
    ///
    /// Returns the number of new bytes, or 0 when nothing new has arrived
    /// (after sleeping on `sleep_io` so the caller does not busy-loop).
    /// If the file is truncated or rotated, reading resumes from the top.
    pub fn poll(self: *LogFollower, sleep_io: std.Io, buf: []u8) !usize {
        const size: u64 = @intCast(try self.file.length(sleep_io));

        if (size < self.offset) {
            // Truncated or rotated: restart from the beginning.
            self.offset = 0;
        }
        if (size <= self.offset) {
            try std.Io.sleep(sleep_io, std.Io.Duration.fromMilliseconds(100), .awake);
            return 0;
        }

        const to_read: usize = @intCast(@min(@as(u64, buf.len), size - self.offset));
        const n = try self.file.readPositionalAll(sleep_io, buf[0..to_read], self.offset);
        self.offset += n;
        return n;
    }
};

test "count_head_lines: fewer lines than requested returns full buffer" {
    const buf = "line1\nline2\n";
    try std.testing.expectEqual(@as(usize, buf.len), count_head_lines(buf, 10));
}

test "count_head_lines: exact number of lines" {
    const buf = "line1\nline2\nline3\n";
    try std.testing.expectEqual(@as(usize, 18), count_head_lines(buf, 3));
}

test "count_head_lines: empty buffer" {
    try std.testing.expectEqual(@as(usize, 0), count_head_lines("", 5));
}

test "count_tail_lines: fewer lines than requested returns full buffer" {
    const buf = "line1\nline2\n";
    try std.testing.expectEqual(@as(usize, 0), count_tail_lines(buf, 10));
}

test "count_tail_lines: last two lines of three" {
    const buf = "line1\nline2\nline3\n";
    try std.testing.expectEqual(@as(usize, 6), count_tail_lines(buf, 2));
}

test "count_tail_lines: last line only" {
    const buf = "line1\nline2\nline3\n";
    try std.testing.expectEqual(@as(usize, 12), count_tail_lines(buf, 1));
}

test "count_tail_lines: empty buffer" {
    try std.testing.expectEqual(@as(usize, 0), count_tail_lines("", 5));
}

fn temp_logs_dir(dir: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{&dir.sub_path});
}

test "read_log_tail: reads matching log file" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "mynode.log", .data = "hello from mynode" });

    var logs_dir_buf: [128]u8 = undefined;
    const logs_dir = try temp_logs_dir(&dir, &logs_dir_buf);

    var buf: [4096]u8 = undefined;
    const len = try read_log_tail(logs_dir, "mynode", 10, &buf);
    try std.testing.expectEqualStrings("hello from mynode", buf[0..len]);
}

test "read_log_tail: no matching file returns zero" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "other.log", .data = "hello" });

    var logs_dir_buf: [128]u8 = undefined;
    const logs_dir = try temp_logs_dir(&dir, &logs_dir_buf);

    var buf: [4096]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try read_log_tail(logs_dir, "mynode", 10, &buf));
}

test "read_log_head: reads first lines of log file" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(std.testing.io, .{ .sub_path = "sensor.log", .data = "line1\nline2\nline3\nline4\nline5\n" });

    var logs_dir_buf: [128]u8 = undefined;
    const logs_dir = try temp_logs_dir(&dir, &logs_dir_buf);

    var buf: [4096]u8 = undefined;
    const len = try read_log_head(logs_dir, "sensor", 2, &buf);
    try std.testing.expectEqualStrings("line1\nline2\n", buf[0..len]);
}

test "LogFollower: streams appended bytes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();

    try dir.dir.writeFile(io, .{ .sub_path = "stream.log", .data = "line1\n" });

    const logs_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&dir.sub_path});
    defer allocator.free(logs_dir);

    var follower = try LogFollower.init(logs_dir, "stream");
    defer follower.deinit();

    var buf: [256]u8 = undefined;
    // Existing content is not re-streamed: nothing new yet.
    try std.testing.expectEqual(@as(usize, 0), try follower.poll(io, &buf));

    // Append more and poll again.
    try dir.dir.writeFile(io, .{ .sub_path = "stream.log", .data = "line1\nline2\n" });
    try std.testing.expectEqual(@as(usize, 6), try follower.poll(io, &buf));
    try std.testing.expectEqualStrings("line2\n", buf[0..6]);

    // Truncation resumes from the top.
    try dir.dir.writeFile(io, .{ .sub_path = "stream.log", .data = "fresh\n" });
    try std.testing.expectEqual(@as(usize, 6), try follower.poll(io, &buf));
    try std.testing.expectEqualStrings("fresh\n", buf[0..6]);
}
