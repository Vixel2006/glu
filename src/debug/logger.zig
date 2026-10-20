const std = @import("std");
const constants = @import("../constants.zig");
const time = @import("../time.zig");

const IO = @import("../io.zig");

pub const LogLevel = enum(u8) {
    Error,
    Fatal,
    Info,
    Warning,
};

pub const Logger = struct {
    io: *IO.IO,
    node: []const u8,
    fd: std.posix.fd_t,
    fut: IO.IO.Future = undefined,

    pub fn init(io: *IO.IO, node: []const u8) !Logger {
        _ = std.os.linux.mkdir(constants.LOGS_DIR, 0o755);

        var path_buf: [512:0]u8 = undefined;
        const path = std.fmt.bufPrint(
            path_buf[0 .. 512 - 1],
            "{s}/{s}.log",
            .{ constants.LOGS_DIR, node },
        ) catch return error.NameTooLong;
        path_buf[path.len] = 0;

        var fut: IO.IO.Future = undefined;
        try io.openat(
            &fut,
            std.posix.AT.FDCWD,
            path_buf[0..].ptr,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
            0o644,
        );

        const fd = try io.wait(&fut, std.posix.fd_t);

        return .{ .io = io, .node = node, .fd = fd };
    }

    pub fn deinit(self: *Logger) void {
        self.io.close(&self.fut, self.fd) catch {};
        self.io.wait(&self.fut, void) catch {};
    }

    pub fn log(self: *Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) !void {
        var ts_buf: [32]u8 = undefined;
        const ts = format_timestamp(&ts_buf);

        var line_buf: [1024]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &line_buf,
            "[{s}] [{s}] [{s}] " ++ fmt ++ "\n",
            .{ self.node, ts, @tagName(level) } ++ args,
        );

        try self.io.write(&self.fut, self.fd, line, 0);
        _ = try self.io.wait(&self.fut, usize);
    }
};

fn format_timestamp(buf: []u8) []const u8 {
    const secs = time.wallclock() catch 0;
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
}
