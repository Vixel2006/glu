const std = @import("std");
const glu = @import("glu");
const msgs = @import("msgs.zig");

// -- configuration -----------------------------------------------------------
const topic = "/telemetry";
const capacity = 4096;
const publish_rate_hz = 100; // messages per second
const num_messages = 10_000;

// -- helpers -----------------------------------------------------------------
fn milliTimestamp() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn sleepMs(ms: u64) void {
    var ts = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.os.linux.nanosleep(&ts, null);
}

// -- main --------------------------------------------------------------------
pub fn main() void {
    const allocator = std.heap.page_allocator;

    var publisher = glu.Publisher.init(
        allocator,
        topic,
        @sizeOf(msgs.Telemetry),
        capacity,
    ) catch |e| {
        std.debug.print("[sensor] publisher init failed: {}\n", .{e});
        return;
    };
    defer publisher.deinit();

    std.debug.print(
        "[sensor] publishing {d} messages on '{s}' at {d} Hz\n",
        .{ num_messages, topic, publish_rate_hz },
    );

    const interval_ms: u64 = 1000 / publish_rate_hz;
    const start = milliTimestamp();
    var seq: u32 = 0;

    while (seq < num_messages) : (seq += 1) {
        const msg = msgs.Telemetry{
            .seq = seq,
            .timestamp = milliTimestamp(),
            .temperature = 25.0 + @as(f32, @floatFromInt(seq % 100)) * 0.1,
            .pressure = 1013.25 + @as(f32, @floatFromInt(seq % 50)) * 0.1,
            .humidity = 45.0 + @as(f32, @floatFromInt(seq % 30)) * 0.2,
            .altitude = 100.0 + @as(f32, @floatFromInt(seq)) * 0.01,
        };
        publisher.publish(msgs.Telemetry, &msg);
        sleepMs(interval_ms);
    }

    const elapsed = milliTimestamp() - start;
    std.debug.print(
        "[sensor] done: published {d} msgs in {d} ms\n",
        .{ num_messages, elapsed },
    );
}
