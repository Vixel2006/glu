const std = @import("std");
const os = std.os.linux;

const protocol = @import("../daemon/protocol.zig");

pub fn writer(init: std.process.Init) std.Io.File.Writer {
    return std.Io.File.stdout().writerStreaming(init.io, &.{});
}

pub fn err_writer(init: std.process.Init) std.Io.File.Writer {
    return std.Io.File.stderr().writerStreaming(init.io, &.{});
}

/// "1h2m", "3m4s", or "5s"; "-" when uptime is unknown.
pub fn format_uptime(buf: []u8, secs: u64) []const u8 {
    if (secs == 0) return "-";
    const h = secs / 3600;
    const m = (secs % 3600) / 60;
    const s = secs % 60;
    if (h > 0) return std.fmt.bufPrint(buf, "{d}h{d}m", .{ h, m }) catch "-";
    if (m > 0) return std.fmt.bufPrint(buf, "{d}m{d}s", .{ m, s }) catch "-";
    return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "-";
}

/// Seconds since the node was spawned, from its `CLOCK.BOOTTIME` stamp.
pub fn uptime_secs(node: *const protocol.Node) u64 {
    const started = node.uptime orelse return 0;
    var ts: os.timespec = undefined;
    if (os.clock_gettime(os.CLOCK.BOOTTIME, &ts) != 0) return 0;
    const now: u64 = @intCast(@max(@as(i64, ts.sec), 0));
    const then: u64 = @intCast(@max(@as(i64, started.sec), 0));
    return if (now > then) now - then else 0;
}
