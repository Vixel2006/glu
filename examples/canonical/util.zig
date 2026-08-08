const std = @import("std");
const glu = @import("glu");
const IO = glu.IO;

/// Wall-clock time in milliseconds (REALTIME).
pub fn milli_timestamp() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Sleep in a node's event loop using an io_uring `timeout` op instead of a
/// plain `nanosleep`. This keeps every wait inside the ring, so the same IO
/// engine that services TCP/UDP also paces the loop.
pub fn timer_sleep(io: *IO, ms: u64) void {
    var ts: std.os.linux.kernel_timespec = .{
        .sec = @as(i64, @intCast(ms / 1000)),
        .nsec = @as(i64, @intCast((ms % 1000) * std.time.ns_per_ms)),
    };
    var compl: IO.Future = undefined;
    io.timeout(&compl, &ts, 0) catch return;
    io.wait(&compl, void) catch return;
}
