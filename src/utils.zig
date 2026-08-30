const std = @import("std");

pub const is_alive = @import("utils/process.zig").is_alive;

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

/// Seconds since the process started, or 0 if it cannot be determined.
pub fn proc_uptime(pid: u32) u64 {
    const c = std.c;
    const os = std.os.linux;
    const tck: u64 = @intCast(@max(c.sysconf(2), 1)); // _SC_CLK_TCK

    var buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{pid}) catch return 0;
    buf[path.len] = 0;

    const fd = c.open(buf[0..path.len :0], os.O{ .ACCMODE = .RDONLY });
    if (fd == -1) return 0;
    defer _ = c.close(fd);

    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return 0;

    var i: usize = 0;
    while (i < n and buf[i] != ')') i += 1;
    if (i >= n) return 0;
    i += 1;

    var field: usize = 0;
    var start_ticks: u64 = 0;
    while (i < n and field < 20) {
        while (i < n and buf[i] == ' ') i += 1;
        if (i >= n) break;
        field += 1;
        const j = i;
        while (i < n and buf[i] != ' ') i += 1;
        if (field == 20) {
            start_ticks = std.fmt.parseInt(u64, buf[j..i], 10) catch return 0;
            break;
        }
    }
    if (field < 20) return 0;

    var ts: os.timespec = undefined;
    if (os.clock_gettime(os.CLOCK.BOOTTIME, &ts) != 0) return 0;
    const now_boot: u64 = @intCast(@max(@as(i64, ts.sec), 0));
    const started = @divTrunc(start_ticks, tck);

    return if (now_boot > started) now_boot - started else 0;
}